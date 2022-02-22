defmodule Bonfire.Social.Acts.Caretaker do
  @moduledoc """
  An act that deals with maintaining a `Caretaker` record for a changeset.

  During insertion, adds an associated insert if a caretaker can be found in the epic options.

  During deletion, ensures that the related record will be cleaned up.

  Epic Options (insert):
    * `:caretaker` - user that will take care of the post, falls back to `:current_user`
    * `:current_user` - user that will taker care of the post, fallback if `:caretaker` is not set.
  
  Act Options:
    * `:on` - key to find changeset, required.
  """

  alias Bonfire.Epics.{Act, Epic}
  alias Ecto.Changeset
  require Act
  use Arrows

  def run(epic, act) do
    on = act.options[:on]
    changeset = epic.assigns[on]
    current_user = epic.assigns.options[:current_user]
    cond do
      epic.errors != [] ->
        Act.debug(epic, act, length(epic.errors), "Skipping due to epic errors")
        epic
      is_nil(on) or not is_atom(on) ->
        Act.debug(epic, act, on, "Skipping due to `on` option")
        epic
      not is_struct(changeset) || changeset.__struct__ != Changeset ->
        Act.debug(epic, act, changeset, "Skipping :#{on} due to changeset")
        epic
      changeset.action not in [:insert, :delete] ->
        Act.debug(epic, act, changeset.action, "Skipping, no matching action on changeset")
        epic
      changeset.action == :insert ->
        case epic.assigns.options[:caretaker] do
          %{id: id} ->
            Act.debug(epic, act, id, "Casting explicit caretaker")
            cast(epic, act, changeset, on, id)
          id when is_binary(id) ->
            Act.debug(epic, act, id, "Casting explicit caretaker")
            cast(epic, act, changeset, on, id)
          nil ->
            case current_user do
              %{id: id} ->
                Act.smart(epic, act, current_user, "Casting current user as caretaker #{id}")
                cast(epic, act, changeset, on, id)
              id when is_binary(id) ->
                Act.debug(epic, act, id, "Casting current user as caretaker")
                cast(epic, act, changeset, on, id)
              other ->
                Act.smart(epic, act, current_user, "Skipping because of current user")
                epic
            end
          other ->
            Act.warn(other, "Invalid custom caretaker")
            epic
        end
      changeset.action == :delete ->
        # TODO: deletion
        epic
    end
  end

  defp cast(epic, act, changeset, on, id) do
    changeset
    |> Changeset.cast(%{caretaker: %{caretaker_id: id}}, [])
    |> Changeset.cast_assoc(:caretaker)
    |> Epic.assign(epic, on, ...)
  end

end
