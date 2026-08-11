defmodule Bonfire.Social.Localise do
  @moduledoc """
  Registers this extension's runtime-derived strings for gettext extraction, at compile time.

  Activity verbs are conjugated into English past tense by `Bonfire.Social.Activities.verb_display/1` *before* being localised, so the msgid is "Boosted" rather than "Boost" which is already unambiguous. The `"verb: past tense"` context is here for guidance rather than disambiguation: a translator seeing a bare "Boosted" cannot tell it lands after a name in a feed line.

  Two sets are emitted, because they are different grammatical forms and `localise_strings/3` applies one context per list: the past-tense forms ("Boosted", "Requested to follow") under `"verb: past tense"`, and the base "Request to …" phrases context-less, matching how `bonfire_boundaries` leaves its capability names bare.

  The phrases are enumerated whole rather than interpolated as `"%{verb} to %{other}"`. The governed verb's form depends on the verb governing it, French wants "a demandé à suivre", `à` plus a lowercase infinitive, and case-marking languages need more, so a placeholder would hand the translator something they cannot inflect. Interpolate data; enumerate phrases.

  This lives in `bonfire_social` rather than in a flavour extension because `Activities.all_verb_names/0` falls back to the `:verb_names` config (set statically in `config/bonfire_data.exs`), so it resolves at this extension's own compile time without needing sibling apps loaded. Keeping it here also puts the strings in the `bonfire_social` gettext domain, the same domain `verb_display/1` looks them up in, which is the whole point (a domain mismatch between extraction and lookup is silent).
  """

  use Bonfire.Common.Localise

  Bonfire.Social.Activities.all_verb_names_conjugated()
  |> localise_strings(Bonfire.Social.Activities, "verb: past tense")

  # base form, so no context — same treatment as the capability names `bonfire_boundaries` declares
  Bonfire.Social.Activities.all_verb_names_request_phrases()
  |> localise_strings(Bonfire.Social.Activities)
end
