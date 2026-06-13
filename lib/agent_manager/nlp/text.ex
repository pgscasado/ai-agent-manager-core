defmodule AgentManager.NLP.Text do
  @moduledoc "Small text helpers shared by retrieval, training and detection."

  @stopwords %{
    "pt" =>
      ~w(a à ao aos as às até com como da das de dela dele deles demais depois do dos e é ela elas ele eles em entre era essa esse esta está estão este eu foi for há isso isto já la lhe mais mas me mesmo meu minha muito na nas nem no nos nós o os ou para pela pelas pelo pelos por qual quando que quem se sem ser seu sua são só também te tem tu tua um uma umas uns você vocês vos fica pra pro tá né oi olá obrigado sim não),
    "en" =>
      ~w(a about above after again all am an and any are as at be because been before being below between both but by can could did do does doing down during each few for from further had has have having he her here hers him his how i if in into is it its itself just me more most my no nor not now of off on once only or other our out over own same she should so some such than that the their them then there these they this those through to too under until up very was we were what when where which while who whom why will with would you your yes hi hello thanks please),
    "es" =>
      ~w(a al algo como con de del desde donde el ella ellos en entre era es esa ese esta estas este esto hay la las le les lo los más me mi muy nada ni no nos o para pero por porque que quien se sin sobre su sus también te tiene todo tu un una uno usted y ya hola gracias sí),
    "fr" =>
      ~w(à au aux avec ce ces dans de des du elle en est et eux il ils je la le les leur lui ma mais me même mes moi mon ne nos notre nous on ou où par pas pour qu que qui sa se ses son sur ta te tes toi ton tu un une vos votre vous bonjour merci oui non),
    "it" =>
      ~w(a ai al alla anche che chi ci come con da dal dei del della di e è gli ha ho i il in io la le lei lo loro lui ma mi mio ne nel no noi non o per più quale questo se si sono su sua suo tu tutto un una uno voi ciao grazie sì),
    "de" =>
      ~w(aber als am an auch auf aus bei bin bis bist da das dass dein der des die dir du ein eine einem einen einer er es für hat hatte ich ihr im in ist ja kein mein mit nach nicht noch nur oder sein sich sie sind so über um und uns von vor war was wie wir zu zum zur hallo danke bitte nein)
  }

  def stopwords, do: @stopwords

  @doc "Lowercases and removes accents (NFD + strip combining marks)."
  def normalize(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
  end

  def words(text), do: String.split(text, ~r/[^\p{L}\p{N}]+/u, trim: true)

  @doc """
  Normalises text before embedding: drops URLs, punctuation, accents and
  stopwords (Portuguese by default) - used to build the text that gets embedded.
  """
  def remove_stopwords(text, languages \\ ["pt"]) do
    stop =
      languages
      |> Enum.flat_map(&Map.get(@stopwords, &1, []))
      |> Enum.map(&normalize/1)
      |> MapSet.new()

    text
    |> String.replace(~r/(?:https?|ftp):\/\/\S+/u, "")
    |> normalize()
    |> words()
    |> Enum.reject(&MapSet.member?(stop, &1))
    |> Enum.join(" ")
  end

  @doc "Cosine similarity of two equal-length vectors."
  def cosine(a, b) do
    {dot, na, nb} =
      Enum.zip_reduce(a, b, {0.0, 0.0, 0.0}, fn x, y, {d, n1, n2} ->
        {d + x * y, n1 + x * x, n2 + y * y}
      end)

    if na == 0.0 or nb == 0.0, do: 0.0, else: dot / (:math.sqrt(na) * :math.sqrt(nb))
  end
end
