defmodule Bonfire.Social.LivePush.Activity do
  use Bonfire.Common.Utils
  alias Bonfire.Epics.Act
  alias Bonfire.Social.LivePush
  require Act

  def run(epic, act) do
    if epic.errors == [] do
      activity_key = Keyword.get(act.options, :activity, :activity)
      feeds_key = Keyword.get(act.options, :feeds, :feed_ids)
      case epic.assigns[activity_key] do
        nil ->
          Act.debug(act, "No activity at assign #{activity_key}!")
        activity ->
          Act.debug(act, "Publishing activity at assign #{activity_key}") ##{inspect activity}
          feeds = Map.get(epic.assigns, feeds_key, [])
          Act.debug(act, "Publishing to feeds at assign #{feeds_key}: #{inspect feeds}")
          LivePush.push_activity(feeds, activity)
      end
    else
      Act.debug(act, length(epic.errors), "Skipping due to errors!")
    end
    epic
  end
end
