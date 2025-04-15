defmodule Bonfire.Social.Acts.Objects.Delete do
  @moduledoc """
  Delete something + specified associations with a changeset
  """

  # alias Bonfire.Ecto.Acts.Work
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic

  alias Bonfire.Social
  # alias Ecto.Changeset
  use Arrows
  import Bonfire.Epics
  # import Untangle

  # see module documentation
  @doc false
  def run(epic, act) do
    # current_account = epic.assigns[:options][:current_account]
    # current_user = Bonfire.Common.Utils.current_user(epic.assigns[:options])
    ap_on = Keyword.get(act.options, :ap_on, :ap_object)

    cond do
      epic.errors != [] ->
        maybe_debug(epic, act, length(epic.errors), "Skipping due to epic errors")
        epic

      # not (is_struct(current_user) or is_binary(current_user) or is_struct(current_account) or
      #          is_binary(current_account)) ->
      #   maybe_debug(
      #     epic,
      #     act,
      #     [current_account: current_account, current_user: current_user],
      #     "Skipping due to missing current account or user"
      #   )

      #   epic

      true ->
        as = Keyword.get(act.options, :as, :object)
        maybe_debug(epic, act, as, "Assigning changeset using object from")

        object =
          Keyword.get(epic.assigns[:options], as, %{})
          #  preloads needed to be able to federate deletions, and for is_local?
          |> Social.repo().maybe_preload([:character, :peered, created: [creator: :peered]])

        maybe_debug(epic, act, object, "Delete object")

        id = Map.get(object, :id)

        ap_object =
          ActivityPub.Object.get_cached!(pointer: id) ||
            ActivityPub.Actor.get_cached!(pointer: id)

        epic
        |> Epic.assign(as, object)
        |> Epic.assign(ap_on, ap_object)
        |> Epic.assign(
          :ap_bcc,
          ActivityPub.Actor.get_external_followers(ap_object, :deletion)
          |> Bonfire.Federate.ActivityPub.AdapterUtils.ids_or_object_ids()
        )
        |> IO.inspect(label: "deletion epic setup")

        # |> Work.add(:object)
    end
  end
end
