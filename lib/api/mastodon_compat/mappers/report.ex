if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.MastoCompat.Mappers.Report do
    @moduledoc "Transforms Bonfire Flag objects to Mastodon Report format."

    use Bonfire.Common.Utils
    import Untangle

    alias Bonfire.Social.API.MastoCompat.Schemas
    alias Bonfire.API.MastoCompat.{Helpers, Mappers}
    alias Bonfire.Common.DatesTimes

    def from_flag(flag, opts \\ [])
    def from_flag(nil, _opts), do: nil

    def from_flag(flag, opts) when is_map(flag) do
      case build_report(flag, opts) do
        %{"id" => id, "target_account" => account} = report
        when not is_nil(id) and not is_nil(account) ->
          report

        other ->
          warn(other, "Failed to build valid report - missing required fields")
          nil
      end
    end

    def from_flag(_, _opts), do: nil

    defp build_report(flag, opts) do
      edge = Helpers.get_field(flag, :edge)
      flagged = Helpers.get_field(edge, :object)
      target_account = extract_target_account(flagged, opts)

      named = Helpers.get_field(flag, :named)
      comment = Helpers.get_field(named, :name) || ""

      status_ids = extract_status_ids(flagged)

      # ULID contains timestamp
      flag_id = Helpers.get_field(flag, :id) || Helpers.get_field(edge, :id)
      created_at = extract_created_at(flag_id)

      Schemas.Report.new(%{
        "id" => Helpers.to_string_safe(flag_id),
        "action_taken" => false,
        "action_taken_at" => nil,
        "category" => "other",
        "comment" => comment,
        "forwarded" => false,
        "created_at" => created_at,
        "status_ids" => status_ids,
        "rule_ids" => nil,
        "target_account" => target_account
      })
    end

    defp extract_target_account(nil, _opts), do: nil

    defp extract_target_account(flagged, opts) do
      object_type = Bonfire.Common.Types.object_type(flagged)

      user =
        if object_type in [Bonfire.Data.Identity.User, Bonfire.Data.Identity.Character] do
          flagged
        else
          created = Helpers.get_field(flagged, :created)
          Helpers.get_field(created, :creator)
        end

      debug(user, "target user for report")

      account_opts = Keyword.put_new(opts, :skip_expensive_stats, true)
      Mappers.Account.from_user(user, account_opts)
    end

    defp extract_status_ids(nil), do: nil

    defp extract_status_ids(flagged) do
      object_type = Bonfire.Common.Types.object_type(flagged)

      if object_type in [Bonfire.Data.Identity.User, Bonfire.Data.Identity.Character] do
        nil
      else
        case Helpers.get_field(flagged, :id) do
          nil -> nil
          id -> [to_string(id)]
        end
      end
    end

    defp extract_created_at(nil), do: nil

    defp extract_created_at(id) when is_binary(id) do
      case DatesTimes.date_from_pointer(id) do
        %DateTime{} = dt -> DateTime.to_iso8601(dt)
        _ -> DateTime.utc_now() |> DateTime.to_iso8601()
      end
    end

    defp extract_created_at(_), do: nil
  end
end
