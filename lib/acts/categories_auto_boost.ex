defmodule Bonfire.Social.Acts.CategoriesAutoBoost do
  use Bonfire.Common.Utils
  alias Bonfire.Epics
  alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic

  alias Bonfire.Social.LivePush
  import Epics

  def run(epic, act) do
    if epic.errors == [] do
      on = Keyword.get(act.options, :on, :activity)
      key = :categories_auto_boost
      categories_auto_boost = e(epic.assigns, key, [])

      maybe_debug(
        epic,
        act,
        categories_auto_boost,
        "Maybe auto-boosting to categories at assign #{key}"
      )

      case epic.assigns[on] do
        nil ->
          maybe_debug(epic, act, on, "Skipping: no activity at")

        %{object: %{id: _} = object} ->
          Bonfire.Social.Tags.auto_boost(categories_auto_boost, object)

          epic

        object ->
          Bonfire.Social.Tags.auto_boost(categories_auto_boost, object)

          epic
      end
    else
      maybe_debug(act, length(epic.errors), "Skipping due to errors!")
      epic
    end
  end
end
