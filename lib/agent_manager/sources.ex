defmodule AgentManager.Sources do
  @moduledoc """
  Downloads a training file and turns it into text (or rows, for sheets).

  Parsers are chosen by extension and are swappable:

      config :agent_manager, AgentManager.Sources,
        parsers: %{"pdf" => MyOCRParser}

  A parser implements `parse(binary) :: {:ok, String.t() | [map()]} | {:error, term}`.
  """

  @callback parse(binary()) :: {:ok, String.t() | [map()]} | {:error, term()}

  alias AgentManager.Attachments

  @defaults %{
    "pdf" => __MODULE__.PDF,
    "docx" => __MODULE__.Docx,
    "xlsx" => __MODULE__.Xlsx,
    "csv" => __MODULE__.CSV,
    "txt" => __MODULE__.Text,
    "md" => __MODULE__.Text
  }

  def parsers,
    do: Map.merge(@defaults, Application.get_env(:agent_manager, __MODULE__, [])[:parsers] || %{})

  @doc "Fetches `url` and parses it according to its extension."
  def fetch(url, opts \\ []) do
    with {:ok, body, content_type} <- download(url, opts),
         ext = extension(url, content_type),
         {:ok, parser} <- parser_for(ext) do
      parser.parse(body)
    end
  end

  defp parser_for(ext) do
    case Map.fetch(parsers(), ext) do
      {:ok, parser} -> {:ok, parser}
      :error -> {:error, {:unsupported_extension, ext}}
    end
  end

  defp extension(url, content_type) do
    case Attachments.extension(url) do
      "" ->
        content_type
        |> to_string()
        |> String.split(";")
        |> hd()
        |> MIME.extensions()
        |> List.first() || "txt"

      "doc" ->
        "docx"

      "xls" ->
        "xlsx"

      ext ->
        String.downcase(ext)
    end
  end

  defp download(url, opts) do
    [url: url, decode_body: false, receive_timeout: 60_000, retry: :transient]
    |> Keyword.merge(opts[:req_options] || [])
    |> Req.get()
    |> case do
      {:ok, %Req.Response{status: 200, body: body} = resp} ->
        {:ok, body, List.first(Req.Response.get_header(resp, "content-type"))}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, e} ->
        {:error, e}
    end
  end

  # -- parsers -----------------------------------------------------------------

  defmodule Text do
    @moduledoc false
    @behaviour AgentManager.Sources
    @impl true
    def parse(body), do: {:ok, body}
  end

  defmodule CSV do
    @moduledoc false
    @behaviour AgentManager.Sources
    @impl true
    def parse(body) do
      case NimbleCSV.RFC4180.parse_string(body, skip_headers: false) do
        [headers | rows] -> {:ok, Enum.map(rows, &(Enum.zip(headers, &1) |> Map.new()))}
        [] -> {:ok, []}
      end
    rescue
      e -> {:error, e}
    end
  end

  defmodule PDF do
    @moduledoc "Uses poppler's `pdftotext` (install `poppler-utils`)."
    @behaviour AgentManager.Sources
    @impl true
    def parse(body) do
      if exe = System.find_executable("pdftotext") do
        path = Path.join(System.tmp_dir!(), "am-#{System.unique_integer([:positive])}.pdf")
        File.write!(path, body)

        try do
          case System.cmd(exe, ["-layout", path, "-"], stderr_to_stdout: true) do
            {text, 0} -> {:ok, text}
            {out, code} -> {:error, {:pdftotext, code, out}}
          end
        after
          File.rm(path)
        end
      else
        {:error, :pdftotext_not_installed}
      end
    end
  end

  defmodule Docx do
    @moduledoc "Reads `word/document.xml` straight from the zip, one paragraph per block."
    @behaviour AgentManager.Sources
    @impl true
    def parse(body) do
      with {:ok, [{_, xml}]} <- :zip.unzip(body, [:memory, file_list: [~c"word/document.xml"]]) do
        text =
          xml
          |> String.replace(~r/<\/w:p>/, "\n\n")
          |> String.replace(~r/<w:tab\/>/, "\t")
          |> String.replace(~r/<[^>]+>/, "")
          |> AgentManager.Sources.Xml.unescape()

        {:ok, text}
      else
        _ -> {:error, :invalid_docx}
      end
    end
  end

  defmodule Xlsx do
    @moduledoc "First worksheet as a list of row maps keyed by the header row."
    @behaviour AgentManager.Sources
    alias AgentManager.Sources.Xml

    @impl true
    def parse(body) do
      with {:ok, files} <- :zip.unzip(body, [:memory]) do
        files = Map.new(files, fn {name, data} -> {to_string(name), data} end)
        shared = shared_strings(files["xl/sharedStrings.xml"])

        sheet =
          files
          |> Map.keys()
          |> Enum.filter(&String.starts_with?(&1, "xl/worksheets/sheet"))
          |> Enum.sort()
          |> List.first()

        rows =
          Regex.scan(~r/<row[^>]*>(.*?)<\/row>/s, files[sheet] || "", capture: :all_but_first)
          |> Enum.map(fn [row] -> cells(row, shared) end)

        case rows do
          [headers | data] ->
            {:ok,
             Enum.map(data, fn row ->
               headers |> Enum.with_index() |> Map.new(fn {h, i} -> {h, Enum.at(row, i, "")} end)
             end)}

          [] ->
            {:ok, []}
        end
      else
        _ -> {:error, :invalid_xlsx}
      end
    end

    defp shared_strings(nil), do: {}

    defp shared_strings(xml) do
      Regex.scan(~r/<si>(.*?)<\/si>/s, xml, capture: :all_but_first)
      |> Enum.map(fn [si] -> si |> String.replace(~r/<[^>]+>/, "") |> Xml.unescape() end)
      |> List.to_tuple()
    end

    defp cells(row, shared) do
      Regex.scan(~r/<c ([^>]*?)(?:\/>|>(.*?)<\/c>)/s, row, capture: :all_but_first)
      |> Enum.map(fn
        [attrs, inner] -> value(attrs, inner, shared)
        [_attrs] -> ""
      end)
    end

    defp value(attrs, inner, shared) do
      raw =
        case Regex.run(~r/<v>(.*?)<\/v>/s, inner) do
          [_, v] -> v
          _ -> inner |> String.replace(~r/<[^>]+>/, "")
        end

      if String.contains?(attrs, ~s(t="s")),
        do: elem(shared, String.to_integer(raw)),
        else: Xml.unescape(raw)
    end
  end

  defmodule Xml do
    @moduledoc false
    def unescape(text) do
      text
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&quot;", "\"")
      |> String.replace("&apos;", "'")
      |> String.replace("&amp;", "&")
    end
  end
end
