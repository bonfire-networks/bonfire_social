if Application.compile_env(:bonfire_social, :modularity) != :disabled do
  defmodule Bonfire.Social.Web.MastoReportController do
    @moduledoc """
    Mastodon-compatible Reports endpoints.

    Implements the reports API following Mastodon API conventions:
    - POST /api/v1/reports - Create a new report
    - GET /api/v1/reports - List user's own reports
    - GET /api/v1/reports/:id - Get a specific report

    In Bonfire, Reports are implemented using Flags.
    This is a thin controller that delegates to the adapter.
    """
    use Bonfire.UI.Common.Web, :controller
    import Untangle

    alias Bonfire.Social.API.GraphQLMasto.Adapter

    def create(conn, params) do
      debug(params, "POST /api/v1/reports")
      Adapter.create_report(params, conn)
    end

    def index(conn, params) do
      debug(params, "GET /api/v1/reports")
      Adapter.list_reports(params, conn)
    end

    def show(conn, params) do
      debug(params, "GET /api/v1/reports/#{params["id"]}")
      Adapter.show_report(params, conn)
    end
  end
end
