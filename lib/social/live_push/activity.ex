defmodule Bonfire.Social.LivePush.Activity do
  use Bonfire.Common.Utils
  alias Bonfire.Epics.Act
  alias Bonfire.Social.LivePush
  require Act

  def run(epic, act) do
    if epic.errors == [] do
      activity_key = Keyword.get(act.options, :activity, :activity)
      feeds_key = Keyword.get(act.options, :feeds, :publish_feeds)
      case epic.assigns[activity_key] do
        nil ->
          Act.debug(act, "No activity at assign #{activity_key}!")
        activity ->
          Act.debug(act, "Publishing activity at assign #{activity_key}")
          feeds = Map.get(epic.assigns, feeds_key, [])
          LivePush.push_activity(feeds, activity)
      end
    else
      Act.debug(act, length(epic.errors), "Skipping due to errors!")
    end
    epic
  end
end
