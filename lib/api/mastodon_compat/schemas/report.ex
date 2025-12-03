if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.MastoCompat.Schemas.Report do
    @moduledoc "Mastodon Report entity schema definition."

    def new(overrides \\ %{}) do
      defaults()
      |> Map.merge(overrides)
    end

    def defaults do
      %{
        "id" => nil,
        "created_at" => nil,
        "action_taken" => false,
        "action_taken_at" => nil,
        "category" => "other",
        "comment" => "",
        "forwarded" => false,
        "status_ids" => nil,
        "rule_ids" => nil,
        "target_account" => nil
      }
    end

    def required_fields do
      ["id", "action_taken", "category", "comment", "forwarded", "created_at", "target_account"]
    end

    def validate(report) when is_map(report) do
      missing =
        required_fields()
        |> Enum.filter(fn field -> is_nil(Map.get(report, field)) end)

      if missing == [] do
        {:ok, report}
      else
        {:error, {:missing_fields, missing}}
      end
    end

    def validate(_), do: {:error, :invalid_report}
  end
end
