defmodule Bonfire.Social.Acts.Objects.Delete do
  @moduledoc """
  Delete something + specified associations with a changeset
  """

  alias Bonfire.Ecto.Acts.Work
  alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic

  alias Bonfire.Social.Posts
  alias Ecto.Changeset
  use Arrows
  import Bonfire.Epics
  import Untangle

  # see module documentation
  @doc false
  def run(epic, act) do
    current_account = epic.assigns[:options][:current_account]
    current_user = epic.assigns[:options][:current_user]

    cond do
      epic.errors != [] ->
        maybe_debug(epic, act, length(epic.errors), "Skipping due to epic errors")
        epic

      not (is_struct(current_user) or is_binary(current_user) or is_struct(current_account) or
               is_binary(current_account)) ->
        maybe_debug(
          epic,
          act,
          [current_account: current_account, current_user: current_user],
          "Skipping due to missing current account or user"
        )

        epic

      true ->
        as = Keyword.get(act.options, :as, :object)
        maybe_debug(epic, act, as, "Assigning changeset using object from")
        object = Keyword.get(epic.assigns[:options], as, %{})
        maybe_debug(epic, act, object, "Delete object")

        object
        |> Epic.assign(epic, as, ...)

        # |> Work.add(:object)
    end
  end
end
