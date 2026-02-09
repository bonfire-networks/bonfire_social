if Application.compile_env(:bonfire_social, :modularity) != :disabled do
  defmodule Bonfire.Social.Web.MastoStatusController do
    @moduledoc "Mastodon-compatible status interaction endpoints (show, delete, like, boost, bookmark)"

    use Bonfire.UI.Common.Web, :controller

    alias Bonfire.Social.API.GraphQLMasto.Adapter

    def show(conn, %{"id" => id}), do: Adapter.show_status(%{"id" => id}, conn)
    def source(conn, %{"id" => id}), do: Adapter.status_source(%{"id" => id}, conn)
    def update(conn, params), do: Adapter.update_status(params, conn)
    def delete(conn, %{"id" => id}), do: Adapter.delete_status(%{"id" => id}, conn)
    def context(conn, %{"id" => id}), do: Adapter.status_context(%{"id" => id}, conn)
    def favourited_by(conn, params), do: Adapter.status_favourited_by(params, conn)
    def reblogged_by(conn, params), do: Adapter.status_reblogged_by(params, conn)
    def favourite(conn, %{"id" => id}), do: Adapter.like_status(%{"id" => id}, conn)
    def unfavourite(conn, %{"id" => id}), do: Adapter.unlike_status(%{"id" => id}, conn)
    def reblog(conn, %{"id" => id}), do: Adapter.boost_status(%{"id" => id}, conn)
    def unreblog(conn, %{"id" => id}), do: Adapter.unboost_status(%{"id" => id}, conn)
    def bookmark(conn, %{"id" => id}), do: Adapter.bookmark_status(%{"id" => id}, conn)
    def unbookmark(conn, %{"id" => id}), do: Adapter.unbookmark_status(%{"id" => id}, conn)
    def pin(conn, %{"id" => id}), do: Adapter.pin_status(%{"id" => id}, conn)
    def unpin(conn, %{"id" => id}), do: Adapter.unpin_status(%{"id" => id}, conn)
  end
end
