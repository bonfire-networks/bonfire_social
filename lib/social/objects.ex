defmodule Bonfire.Social.Objects do

  alias Bonfire.Social.{Activities}
  alias Bonfire.Common.Utils
  # import Bonfire.Common.Hooks

  use Bonfire.Repo.Query,
    schema: Pointers.Pointer,
    searchable_fields: [:id],
    sortable_fields: [:id]


  def read(object_id, socket_or_current_user) when is_binary(object_id) do

    current_user = Utils.current_user(socket_or_current_user)

    with {:ok, object} <- build_query(id: object_id)
      |> Activities.read(socket_or_current_user) do

        {:ok, object |> Bonfire.Common.Pointers.follow!()}
      end
  end

end
