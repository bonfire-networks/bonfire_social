if Application.compile_env(:bonfire_social, :modularity) != :disabled do
  defmodule Bonfire.Social.Web.MastoReportController do
    @moduledoc "Mastodon-compatible Reports endpoints. In Bonfire, Reports are implemented using Flags."

    use Bonfire.UI.Common.Web, :controller

    alias Bonfire.Social.API.GraphQLMasto.Adapter

    def create(conn, params), do: Adapter.create_report(params, conn)
    def index(conn, params), do: Adapter.list_reports(params, conn)
    def show(conn, params), do: Adapter.show_report(params, conn)
  end
end
