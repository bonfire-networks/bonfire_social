defmodule Bonfire.Social.LocaliseTest do
  @moduledoc """
  That every wording a feed row can ask gettext for is a wording gettext was told about.

  These strings are assembled at runtime, so there is no literal call site for `mix gettext.extract` to walk and `Bonfire.Social.Localise` enumerates them instead. A name that misses the enumeration reads as English in every locale and nothing fails, because gettext answers an unknown msgid with the msgid itself. So what is checked here is the extracted catalogue, not any translation: if one of these fails, either the name is missing from the enumeration or `just localise-extract` has not been run since it was added.
  """
  use Bonfire.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Social.Activities

  @catalogue "priv/localisation/bonfire_social.po"

  setup_all do
    %{extracted: File.read!(@catalogue)}
  end

  defp assert_extracted(catalogue, msgid, why) do
    assert catalogue =~ ~s(msgid "#{msgid}"),
           "#{why}: #{inspect(msgid)} is in no catalogue, so it reads as English in every locale. Add it to `Bonfire.Social.Localise`, then run `just localise-extract`."
  end

  test "every verb the registry declares is extracted in the past tense", %{extracted: extracted} do
    for verb <- Activities.all_verb_names() do
      assert_extracted(extracted, Activities.verb_past_tense(verb), "the verb #{inspect(verb)}")
    end
  end

  test "so is what a verb reads as when it was only asked for", %{extracted: extracted} do
    for verb <- Activities.all_verb_names() do
      assert_extracted(
        extracted,
        Activities.verb_past_tense("Request to #{verb}"),
        "asking to #{String.downcase(verb)}"
      )
    end
  end

  test "and so is every kind named by config, which is where a new one gets forgotten", %{
    extracted: extracted
  } do
    for {experience, name} <- Activities.experience_display_names() do
      assert_extracted(
        extracted,
        Activities.verb_past_tense(name),
        "#{inspect(experience)}, named #{inspect(name)}"
      )
    end
  end
end
