defmodule Bonfire.Social.Objects do

  alias Bonfire.Social.{Activities}
  alias Bonfire.Common.Utils

  use Bonfire.Repo,
    schema: Pointers.Pointer,
    searchable_fields: [:id],
    sortable_fields: [:id]


  def read(object_id, socket_or_current_user) when is_binary(object_id) do

    current_user = Utils.current_user(socket_or_current_user) #|> IO.inspect

    with {:ok, pointer} <- Bonfire.Common.Pointers.pointer_query([id: object_id], socket_or_current_user)
                          |> Activities.read(socket: socket_or_current_user, skip_boundary_check: true) #|> IO.inspect,
        #  {:ok, object} <- Bonfire.Common.Pointers.get(pointer, current_user: user)
        do

        # IO.inspect(read_object: pointer)

        {:ok,
          pointer
          |> maybe_preload_activity_object(current_user)
          |> Activities.activity_under_object()
        }
      end
  end

  def maybe_preload_activity_object(%{activity: %{object: _}} = pointer, current_user) do
    pointer
    |> Bonfire.Common.Pointers.Preload.maybe_preload_nested_pointers([activity: [:object]], current_user: current_user, skip_boundary_check: true)
  end
  def maybe_preload_activity_object(pointer, _current_user), do: pointer

  def preload_reply_creator(object) do
    object
    |> Bonfire.Repo.maybe_preload([replied: [reply_to: [created: [creator_character: [:inbox]]]]]) #|> IO.inspect
    # |> Bonfire.Repo.maybe_preload([replied: [:reply_to]]) #|> IO.inspect
    |> Bonfire.Repo.maybe_preload([replied: [reply_to: [creator: [character: [:inbox]]]]]) #|> IO.inspect
  end

  def preload_creator(object) do
    object
    |> Bonfire.Repo.maybe_preload([created: [creator_character: [:inbox]]]) #|> IO.inspect
    |> Bonfire.Repo.maybe_preload([creator: [character: [:inbox]]]) #|> IO.inspect
  end

  def object_creator(object) do
    Utils.e(object, :created, :creator_character, Utils.e(object, :creator, nil))
  end


end
