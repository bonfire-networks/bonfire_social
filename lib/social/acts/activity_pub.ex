# Maybe in future we will seperate this so it's the only AP act
# that needs running in the transaction, but that requires teasing apart
# the old translator first

# defmodule Bonfire.Social.Acts.ActivityPub do

#   alias Bonfire.Epics.{Act, Epic}
#   alias Bonfire.Social.Integration
  # import Epics

#   def run(epic, act) do
#     cond do
#       epic.errors != [] ->
#         maybe_debug(epic, act, length(epic.errors), "Skipping due to epic errors")
#         epic
#         maybe_debug(epic, act, length(epic.errors), "Skipping publish due to epic errors")
#       true ->
#         current_user = Keyword.fetch!(epic.assigns[:options], :current_user)
#         key = Keyword.fetch!(act.options, :activity)
#         case epic.assigns[key] do
#           nil ->
#             maybe_debug(epic, act, "Not publishing to ActivityPub, assign #{key} not found.")
#           activity ->
#             maybe_debug(epic, act, "Enqueueing ActivityPub Worker task for assign #{key}")
#             Integration.ap_push_activity(current_user, activity)
#         end
#     end
#     epic
#   end

# end
