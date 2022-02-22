defmodule Bonfire.Social.Acts.Creator do
  @moduledoc """
  An act that deals with maintaining a `Created` record for a changeset.

  During insertion, adds an associated insert if a creator can be found in the epic options.

  During deletion, ensures that the related record will be cleaned up.

  Epic Options (insert):
    * `:creator` - user that will create the post, falls back to `:current_user`
    * `:current_user` - user that will create the post, fallback if `:creator` is not set.
  
  Act Options:
    * `:on` - key to find changeset, required.
  """

  alias Bonfire.Epics.{Act, Epic}
  alias Ecto.Changeset
  require Act
  use Arrows

  @doc false # see module documentation
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
      changeset.action not in [:insert, :delete] ->
        Act.debug(epic, act, changeset.action, "Skipping, no matching action on changeset")
        epic
      changeset.action == :insert ->
        case epic.assigns.options[:creator] do
          %{id: id} ->
            Act.debug(epic, act, id, "Casting explicit creator")
            cast(epic, act, changeset, on, id)
          id when is_binary(id) ->
            Act.debug(epic, act, id, "Casting explicit creator")
            cast(epic, act, changeset, on, id)
          nil ->
            case current_user do
              %{id: id} ->
                Act.smart(epic, act, current_user, "Casting current user as creator #{id}")
                cast(epic, act, changeset, on, id)
              id when is_binary(id) ->
                Act.debug(epic, act, id, "Casting current user as creator")
                cast(epic, act, changeset, on, id)
              other ->
                Act.smart(epic, act, current_user, "Skipping because of current_user")
                epic
            end
          other ->
            Act.warn(other, "Invalid custom creator")
            epic
        end
      changeset.action == :delete ->
        # TODO: deletion
        epic
    end
  end

  defp cast(epic, act, changeset, on, id) do
    Act.debug(epic, act, "Casting creator #{id}")
    changeset
    |> Changeset.cast(%{created: %{creator_id: id}}, [])
    |> Changeset.cast_assoc(:created)
    |> Epic.assign(epic, on, ...)
  end

end
