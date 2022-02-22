defmodule Bonfire.Social.Acts.LivePush do
  use Bonfire.Common.Utils
  alias Bonfire.Epics.Act
  alias Bonfire.Social.LivePush
  require Act

  def run(epic, act) do
    if epic.errors == [] do
      on = Keyword.get(act.options, :on, :activity)
      feeds_key = Keyword.get(act.options, :feeds, :feed_ids)
      case epic.assigns[on] do
        nil ->
          Act.debug(epic, act, "Skipping: no activity at :#{on}!")
        activity ->
          Act.debug(epic, act, "Publishing activity at :#{on}") ##{inspect activity}
          feeds = Map.get(epic.assigns, feeds_key, [])
          Act.debug(epic,act, "Publishing to feeds at assign #{feeds_key}: #{inspect feeds}")
          LivePush.push_activity(feeds, activity)
      end
    else
      Act.debug(act, length(epic.errors), "Skipping due to errors!")
    end
    epic
  end
end
