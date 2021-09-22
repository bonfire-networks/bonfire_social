defmodule Bonfire.Social.APActivities do
  alias Bonfire.Data.Social.APActivity
  alias Bonfire.Social.FeedActivities

  import Bonfire.Common.Utils
  import Bonfire.Common.Config, only: [repo: 0]

  def create(activity, object, actor) do
    json =
      activity.data
      |> Map.put("object", object.data)

    with {:ok, apactivity} <- insert(json),
         {:ok, _} <- FeedActivities.save_fediverse_incoming_activity(actor, :create, apactivity) do
      {:ok, apactivity}
    end
  end

  def insert(json) do
    %APActivity{}
    |> APActivity.changeset(%{json: json})
    |> repo().insert()
  end
end
