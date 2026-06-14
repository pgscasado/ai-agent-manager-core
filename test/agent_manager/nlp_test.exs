defmodule AgentManager.NLPTest do
  use ExUnit.Case, async: true

  alias AgentManager.{Attachments, JSON}
  alias AgentManager.NLP.{Language, Segmenter, Text}

  test "language detection" do
    assert Language.detect("oi") == "pt"
    assert Language.detect("hello there") == "en"
    assert Language.detect("Qual é o horário de funcionamento da loja?") == "pt"
    assert Language.detect("What are the opening hours of the store?") == "en"
    assert Language.detect("¿Cuál es el horario de la tienda y dónde está?") == "es"
  end

  test "narrowing allowed languages by detected code" do
    assert Language.narrow(["Português brasileiro", "English"], "pt") == ["Português brasileiro"]
    assert Language.narrow(["Portuguese", "English"], "en") == ["English"]
    assert Language.narrow(["Portuguese"], "de") == ["Portuguese"]
  end

  test "stopword removal strips accents, urls and punctuation" do
    assert Text.remove_stopwords("Qual é o preço do produto? Veja https://x.com/a") ==
             "preco produto veja"
  end

  test "segmenter merges short paragraphs and renders sheet rows" do
    text =
      "Horários\n\nAbrimos de segunda a sexta, das 9h às 18h, exceto feriados nacionais e datas especiais.\n\nOutro parágrafo com conteúdo suficiente para ficar sozinho aqui."

    assert [first, second] = Segmenter.segment(text)
    assert first =~ "Horários\nAbrimos"
    assert second =~ "Outro"

    assert Segmenter.segment([%{"produto" => "Camisa", "[attachment]" => "https://x.com/c.png"}]) ==
             [~s([attachment]: "https://x.com/c.png" | produto: "Camisa")]
  end

  test "attachments" do
    seg = %{segment: ~s(produto: "Camisa" | [attachment]: "https://cdn.x.com/camisa.png")}
    assert Attachments.has_attachment?(seg)
    assert Attachments.field(seg) == "https://cdn.x.com/camisa.png"

    assert Attachments.extract_from_response("Veja ANEXO(https://x.com/a.pdf) aqui") == [
             "https://x.com/a.pdf"
           ]

    assert Attachments.extension("https://x.com/a.pdf?x=1") == "pdf"

    assert Attachments.mask(~s(img: "data:image/png;base64,AAAA")) ==
             ~s(img: "data:image/png;base64,...")
  end

  describe "lenient JSON" do
    test "strict, embedded and truncated objects" do
      assert {:ok, %{"a" => 1}} = JSON.decode_object(~s({"a": 1}))

      assert {:ok, %{"response" => "oi"}} =
               JSON.decode_object(~s(Here you go: {"response": "oi"} hope it helps))

      assert {:ok, %{"response" => "oi", "missing_info" => nil}} =
               JSON.decode_object(~s({"response": "oi", "missing_info"))

      assert {:ok, %{"response" => "texto cort"}} =
               JSON.decode_object(~s({"response": "texto cort))

      assert {:error, :invalid_json} = JSON.decode_object("[1,2]")
    end
  end
end
