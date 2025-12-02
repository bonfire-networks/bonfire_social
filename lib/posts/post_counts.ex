defmodule Bonfire.Social.Posts.Counts do
  @moduledoc "Batch loading of post counts for multiple users."

  use Bonfire.Common.Repo
  import Ecto.Query
  alias Bonfire.Common.Types

  def batch_load_for_users(users) when is_list(users) do
    user_ids =
      users
      |> Enum.map(&Types.uid/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if user_ids == [] do
      %{}
    else
      from(c in Bonfire.Data.Social.Created,
        join: p in Bonfire.Data.Social.Post,
        on: c.id == p.id,
        where: c.creator_id in ^user_ids,
        group_by: c.creator_id,
        select: {c.creator_id, count(c.id)}
      )
      |> repo().all()
      |> Map.new()
    end
  end

  def batch_load_for_users(_), do: %{}
end
