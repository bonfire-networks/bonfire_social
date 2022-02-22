# Maybe in future we will seperate this so it's the only AP act
# that needs running in the transaction, but that requires teasing apart
# the old translator first

# defmodule Bonfire.Social.Acts.ActivityPub do

#   alias Bonfire.Epics.{Act, Epic}
#   alias Bonfire.Social.Integration
#   require Act

#   def run(epic, act) do
#     cond do
#       epic.errors != [] ->
#         Act.debug(epic, act, length(epic.errors), "Skipping due to epic errors")
#         epic
#         Act.debug(epic, act, length(epic.errors), "Skipping publish due to epic errors")
#       true ->
#         current_user = Keyword.fetch!(epic.assigns.options, :current_user)
#         key = Keyword.fetch!(act.options, :activity)
#         case epic.assigns[key] do
#           nil ->
#             Act.debug(epic, act, "Not publishing to ActivityPub, assign #{key} not found.")
#           activity ->
#             Act.debug(epic, act, "Enqueueing ActivityPub Worker task for assign #{key}")
#             Integration.ap_push_activity(current_user, activity)
#         end
#     end
#     epic
#   end

# end
