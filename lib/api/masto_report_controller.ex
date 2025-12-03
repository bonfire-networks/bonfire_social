if Application.compile_env(:bonfire_social, :modularity) != :disabled do
  defmodule Bonfire.API.MastoCompatible.ReportController do
    @moduledoc """
    Mastodon-compatible Reports endpoints.

    Implements the reports API following Mastodon API conventions:
    - POST /api/v1/reports - Create a new report
    - GET /api/v1/reports - List user's own reports
    - GET /api/v1/reports/:id - Get a specific report

    In Bonfire, Reports are implemented using Flags.
    """
    use Bonfire.UI.Common.Web, :controller
    use Bonfire.Common.Utils
    import Untangle

    alias Bonfire.Social.Flags
    alias Bonfire.Social.API.MastoCompat.Mappers
    alias Bonfire.API.GraphQL.RestAdapter

    def create(conn, params) do
      debug(params, "POST /api/v1/reports")

      with {:ok, current_user} <- get_current_user(conn),
           {:ok, account_id} <- get_required_param(params, "account_id"),
           flagged_id <- get_flagged_id(params, account_id),
           opts <- build_flag_opts(params),
           {:ok, flag} <- Flags.flag(current_user, flagged_id, opts) do
        flag = preload_for_api(flag)
        report = Mappers.Report.from_flag(flag, current_user: current_user)

        if report do
          RestAdapter.json(conn, report)
        else
          RestAdapter.error_fn({:error, "Failed to create report"}, conn)
        end
      else
        {:error, reason} -> RestAdapter.error_fn({:error, reason}, conn)
      end
    end

    def index(conn, params) do
      debug(params, "GET /api/v1/reports")

      with {:ok, current_user} <- get_current_user(conn) do
        result =
          Flags.list_by(current_user,
            current_user: current_user,
            paginate?: false,
            skip_boundary_check: true,
            preload: :object_with_creator
          )

        flags = extract_flags(result)

        reports =
          flags
          |> Enum.map(&preload_for_api/1)
          |> Enum.map(&Mappers.Report.from_flag(&1, current_user: current_user))
          |> Enum.reject(&is_nil/1)

        RestAdapter.json(conn, reports)
      else
        {:error, reason} -> RestAdapter.error_fn({:error, reason}, conn)
      end
    end

    def show(conn, %{"id" => id} = params) do
      debug(params, "GET /api/v1/reports/#{id}")

      with {:ok, current_user} <- get_current_user(conn),
           {:ok, flag} <- get_flag_by_id(id, current_user) do
        flag = preload_for_api(flag)
        report = Mappers.Report.from_flag(flag, current_user: current_user)

        if report do
          RestAdapter.json(conn, report)
        else
          RestAdapter.error_fn({:error, :not_found}, conn)
        end
      else
        {:error, reason} -> RestAdapter.error_fn({:error, reason}, conn)
      end
    end

    defp get_current_user(conn) do
      case conn.assigns[:current_user] do
        nil -> {:error, :unauthorized}
        user -> {:ok, user}
      end
    end

    defp get_required_param(params, key) do
      case params[key] do
        nil -> {:error, "#{key} is required"}
        "" -> {:error, "#{key} is required"}
        value -> {:ok, value}
      end
    end

    defp get_flagged_id(params, account_id) do
      status_ids = params["status_ids"] || []
      List.first(status_ids) || account_id
    end

    defp build_flag_opts(params) do
      opts = [forward: false]

      case params["comment"] do
        comment when is_binary(comment) and comment != "" ->
          Keyword.put(opts, :comment, String.slice(comment, 0, 1000))

        _ ->
          opts
      end
      |> then(fn opts ->
        if params["forward"] in [true, "true"] do
          Keyword.put(opts, :forward, true)
        else
          opts
        end
      end)
    end

    defp extract_flags(result) do
      case result do
        %{edges: edges} when is_list(edges) -> edges
        flags when is_list(flags) -> flags
        _ -> []
      end
    end

    defp get_flag_by_id(id, current_user) do
      if Types.is_uid?(id) do
        Flags.query([id: id, subjects: current_user], skip_boundary_check: true)
        |> Bonfire.Common.Repo.single()
        |> case do
          {:ok, flag} -> {:ok, flag}
          _ -> {:error, :not_found}
        end
      else
        {:error, :not_found}
      end
    end

    defp preload_for_api(flag) do
      Bonfire.Common.Repo.maybe_preload(
        flag,
        [:named, edge: [:object]],
        follow_pointers: true
      )
      |> then(fn flag ->
        case e(flag, :edge, :object, nil) do
          nil ->
            flag

          object ->
            object =
              Bonfire.Common.Repo.maybe_preload(
                object,
                [:profile, :character, created: [creator: [:profile, :character]]],
                follow_pointers: true
              )

            put_in(flag, [Access.key(:edge), Access.key(:object)], object)
        end
      end)
    end
  end
end
