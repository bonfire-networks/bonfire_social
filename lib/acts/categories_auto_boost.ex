defmodule Bonfire.Social.Acts.CategoriesAutoBoost do
  use Bonfire.Common.Utils
  alias Bonfire.Epics
  alias Bonfire.Epics.{Act, Epic}
  alias Bonfire.Social.LivePush
  import Epics

  def run(epic, act) do
    if epic.errors == [] do
      on = Keyword.get(act.options, :on, :activity)
      key = :categories_auto_boost
      categories_auto_boost = e(epic.assigns, key, [])
      maybe_debug(epic, act, categories_auto_boost, "Maybe auto-boosting to categories at assign #{key}")

      case epic.assigns[on] do
        nil ->
          maybe_debug(epic, act, on, "Skipping: no activity at")

        %{object: %{id: _} = object} ->

          auto_boost(categories_auto_boost, object)

          epic

        object ->

          auto_boost(categories_auto_boost, object)

          epic
      end
    else
      maybe_debug(act, length(epic.errors), "Skipping due to errors!")
      epic
    end
  end

  def auto_boost(categories_auto_boost, object) when is_list(categories_auto_boost) do
    categories_auto_boost
    |> Enum.each(&auto_boost(&1, object))
  end

  def auto_boost(%{} = category, object) do
    Bonfire.Social.Boosts.boost(category, object)

    inbox_id = e(category, :character, :notifications_id, nil)
    |> debug()

    if inbox_id, do: Bonfire.Social.FeedActivities.delete(feed_id: inbox_id, id: ulid(object)) |> debug() # remove it from the "Submitted" tab
  end
end
