defmodule Bonfire.Social.Objects do

  alias Bonfire.Social.{Activities}
  alias Bonfire.Common.Utils

  use Bonfire.Repo.Query,
    schema: Pointers.Pointer,
    searchable_fields: [:id],
    sortable_fields: [:id]


  def read(object_id, socket_or_current_user) when is_binary(object_id) do

    current_user = Utils.current_user(socket_or_current_user)

    with {:ok, pointer} <- Pointers.Pointer
                            |> EctoShorts.filter(id: object_id)
                            |> Activities.read(socket_or_current_user) #|> IO.inspect,
        #  {:ok, object} <- Bonfire.Common.Pointers.get(pointer)
        do

        # IO.inspect(read_object: pointer)

        {:ok,
          pointer
          |> Bonfire.Common.Pointers.Preload.maybe_preload_nested_pointers([activity: [:object]])
          |> Activities.activity_under_object()
        }
      end
  end

end
