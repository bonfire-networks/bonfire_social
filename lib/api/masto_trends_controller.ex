if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.Web.MastoTrendsController do
    @moduledoc "Mastodon-compatible trending endpoints."

    use Bonfire.UI.Common.Web, :controller

    alias Bonfire.API.MastoCompat.Mappers

    @doc """
    GET /api/v1/trends/links

    Returns trending links (PreviewCard entities) based on shared link popularity.
    """
    def links(conn, params) do
      limit =
        case Integer.parse(to_string(params["limit"] || "10")) do
          {n, _} when n > 0 and n <= 20 -> n
          _ -> 10
        end

      offset =
        case Integer.parse(to_string(params["offset"] || "0")) do
          {n, _} when n >= 0 -> n
          _ -> 0
        end

      trending =
        Bonfire.Social.Media.trending_links(limit: limit)
        |> Enum.drop(offset)
        |> Enum.take(limit)
        |> Enum.map(&Mappers.PreviewCard.from_media/1)
        |> Enum.reject(&is_nil/1)

      Phoenix.Controller.json(conn, trending)
    end

    @doc """
    GET /api/v1/trends/statuses - stub returning empty array.
    GET /api/v1/trends/tags - stub returning empty array.
    """
    def statuses(conn, _params), do: Phoenix.Controller.json(conn, [])
    def tags(conn, _params), do: Phoenix.Controller.json(conn, [])
  end
end
