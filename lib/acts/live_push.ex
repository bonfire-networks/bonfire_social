defmodule Bonfire.Social.Acts.LivePush do
  use Bonfire.Common.Utils
  alias Bonfire.Epics
  alias Bonfire.Epics.{Act, Epic}
  alias Bonfire.Social.LivePush
  import Epics

  def run(epic, act) do
    if epic.errors == [] do
      on = Keyword.get(act.options, :on, :activity)
      feeds_key = Keyword.get(act.options, :feeds, :feed_ids)
      case epic.assigns[on] do
        nil ->
          maybe_debug(epic, act, on, "Skipping: no activity at")
        activity ->
          maybe_debug(epic, act, on, "Publishing activity at") ##{inspect activity}
          feeds = Map.get(epic.assigns, feeds_key, [])
          maybe_debug(epic, act, feeds, "Publishing to feeds at assign #{feeds_key}")
          LivePush.push_activity(feeds, activity)
          |> Epic.assign(epic, on, ...)
      end
    else
      maybe_debug(act, length(epic.errors), "Skipping due to errors!")
      epic
    end
  end
end
