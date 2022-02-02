defmodule Bonfire.Social.ActivityPub.Push do

  alias Bonfire.Epics.{Act, Epic}
  alias Bonfire.Social.Integration
  require Act

  def run(epic, act) do
    if epic.errors == [] do
      current_user = Keyword.fetch!(epic.assigns.options, :current_user)
      key = Keyword.fetch!(act.options, :activity)
      case epic.assigns[key] do
        nil ->
          Act.debug(act, "Not publishing to ActivityPub, assign #{key} not found.")
        activity ->
          Act.debug(act, "Enqueueing ActivityPub Worker task for assign #{key}")
          Integration.ap_push_activity(current_user, activity)
      end
    else
      Act.debug(act, "Skipping publish due to epic errors")
    end
    epic
  end

end
