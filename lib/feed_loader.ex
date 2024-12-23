defmodule Bonfire.Social.FeedLoader do
  @moduledoc """
  Determines the appropriate filters, joins, and/or preloads for feed queries based.

  Entrypoint for `Bonfire.Social.Feeds` and `Bonfire.Social.FeedActivities`, and `Bonfire.Social.Activities`.
  """

  use Bonfire.Common.E
  import Untangle
  import Bonfire.Common.Utils
  alias Bonfire.Common.Config
  alias Bonfire.Common.Enums
  alias Bonfire.Common.Types

  @type filter_params :: %{
          feed_name: String.t() | nil,
          feed_ids: list(String.t()) | String.t() | nil,
          activity_types: list(String.t()) | String.t() | nil,
          #  TODO: rename to exclude_activity_types
          exclude_verbs: list(String.t()) | String.t() | nil,
          object_types: list(String.t()) | String.t() | nil,
          media_types: list(String.t()) | String.t() | nil,
          subjects: list(String.t()) | String.t() | nil,
          objects: list(String.t()) | String.t() | nil,
          creators: list(String.t()) | String.t() | nil,
          # TODO
          subject_circles: list(String.t()) | String.t() | nil,
          object_circles: list(String.t()) | String.t() | nil,
          creator_circles: list(String.t()) | String.t() | nil,
          tags: list(String.t()) | String.t() | nil,
          time_limit: integer() | nil,
          sort_by: atom() | nil,
          sort_order: :asc | :desc | nil
        }

  @doc """
  Gets an aliased feed's filters by name, with optional parameters.

  ## Examples

      # 1: Retrieve a preset feed without parameters
      iex> preset_feed_filters(:local, [])
      {:ok, %{feed_name: :local, exclude_verbs: [:like]}}

      # 1: Retrieve a preset feed without parameters
      iex> preset_feed_filters(:local, [])
      {:ok, %{feed_name: :local, exclude_verbs: [:like]}}

      # 2: Retrieve a preset feed with parameters
      iex> preset_feed_filters(:user_activities, [by: "alice"])
      {:ok, %{subjects: "alice"}}

      # 3: Feed not found (error case)
      iex> preset_feed_filters("unknown_feed", [])
      {:error, :not_found}

      # 4: Preset feed with parameterized filters
      iex> preset_feed_filters(:liked_by_me, current_user: %{id: "alice"})
      {:ok, %{activity_types: :like, subjects: %{id: "alice"}}}

      # 5: Feed with `current_user_required` should check for current user
      iex> preset_feed_filters(:messages, current_user: %{id: "alice"})
      {:ok, %{feed_name: :messages}}

      # 6: Feed with `current_user_required` and no current user
      iex> preset_feed_filters(:messages, [])
      ** (Bonfire.Fail.Auth) You need to log in first. 

      # 7: Custom feed with additional parameters
      iex> preset_feed_filters(:user_followers, [by: "alice"])
      {:ok, %{object_types: :follow, objects: "alice"}}
  """
  @spec preset_feed_filters(String.t(), map()) :: {:ok, filter_params()} | {:error, atom()}
  def preset_feed_filters(name, opts \\ []) do
    case feed_definition_if_permitted(name, opts) do
      {:error, e} ->
        {:error, e}

      {:ok, %{parameterized: true, filters: filters}} ->
        {:ok, parameterize_filters(filters, opts)}

      {:ok, %{filters: filters}} ->
        {:ok, filters}
    end
  end

  defp feed_definition_if_permitted(name, opts) when is_atom(name) do
    presets = Bonfire.Social.Feeds.feed_presets()

    case presets[name] do
      nil ->
        debug(presets, "Feed not found: #{name}")
        {:error, :not_found}

      # %{admin_required: true} = alias when not user.is_admin -> 
      #   {:error, :unauthorized} # TODO
      # %{mod_required: true} = alias when not user.is_moderator -> 
      #   {:error, :unauthorized} # TODO
      %{current_user_required: true} = feed_def ->
        if current_user_required!(opts), do: {:ok, feed_def}

      feed_def ->
        {:ok, feed_def}
    end
  end

  defp feed_definition_if_permitted(name, opts) do
    case Types.maybe_to_atom!(name) do
      nil ->
        {:error, :not_found}

      name ->
        feed_definition_if_permitted(name, opts)
    end
  end

  @doc """
  Parameterizes the filters by replacing parameterized values with values from `opts`.

  ## Examples

      # 1: Parameterizing a simple filter
      iex> parameterize_filters(%{subjects: [:me]}, current_user: %{id: "alice"})
      %{subjects: [%{id: "alice"}]}

      # 2: Parameterizing multiple filters
      iex> parameterize_filters(%{subjects: :me, tags: [:hashtag]}, current_user: %{id: "alice"}, hashtag: "elixir")
      %{subjects: %{id: "alice"}, tags: ["elixir"]}

      # 3: Parameterizing with undefined options
      iex> parameterize_filters(%{subjects: :me}, current_user: nil)
      %{subjects: nil}

      # 4: Handling filters that don't require parameterization
      iex> parameterize_filters(%{activity_types: ["like"]}, current_user: "bob")
      %{activity_types: ["like"]}
  """
  def parameterize_filters(filters, opts) do
    filters
    |> Enum.map(fn
      {k, v} when is_list(v) ->
        {k, Enum.map(v, &replace_parameters(&1, opts))}

      {k, v} ->
        {k, replace_parameters(v, opts)}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Replaces parameters in the filter value with the actual values from `opts`.

  ## Examples

      # 1: Replacing a `me` parameter with the current user
      iex> replace_parameters(:me, current_user: %{id: "alice"})
      %{id: "alice"}

      # 2: Replacing a `:current_user` parameter with the current user only if available
      iex> replace_parameters(:current_user, current_user: nil)
      nil

      # 3: Failing with `:current_user_required` parameter if we have no current user
      iex> replace_parameters(:current_user_required, current_user: nil)
      ** (Bonfire.Fail.Auth) You need to log in first. 

      # 4: Handling a parameter that is not in the opts
      iex> replace_parameters(:unknown, current_user: "bob")
      :unknown
  """
  def replace_parameters(:current_user, opts) do
    current_user(opts)
  end

  def replace_parameters(:current_user_required, opts) do
    current_user_required!(opts)
  end

  def replace_parameters(:me, opts) do
    current_user(opts)
  end

  def replace_parameters(value, opts) do
    ed(opts, value, value)
  end

  def replace_parameters(value, _params), do: value

  def preloads_from_filters_rules do
    # Default Rules, TODO: move to config
    Config.get([__MODULE__, :preload_rules], %{})
  end

  @doc """
  Computes the list of preloads to apply based on the provided filters.
  Returns a list of preload atoms.

  Uses rules defined in configuration rather than code.

  Multiple rules can match and their preloads will be merged, with exclusions applied last.

  ## Examples

      iex> filters = %{feed_name: "remote"}
      iex> preloads_from_filters(filters) |> Enum.sort()
      [:with_creator, :with_media, :with_object_more, :with_peered, :with_reply_to, :with_subject]

      iex> filters = %{feed_name: :remote}
      iex> preloads_from_filters(filters) |> Enum.sort()
      [:with_creator, :with_media, :with_object_more, :with_peered, :with_reply_to, :with_subject]

      iex> filters = %{feed_name: ["remote"]}
      iex> preloads_from_filters(filters) |> Enum.sort()
      [:with_creator, :with_media, :with_object_more, :with_peered, :with_reply_to, :with_subject]

      iex> filters = %{feed_name: [:remote]}
      iex> preloads_from_filters(filters) |> Enum.sort()
      [:with_creator, :with_media, :with_object_more, :with_peered, :with_reply_to, :with_subject]

      iex> filters = %{subjects: ["alice"]}
      iex> preloads_from_filters(filters) |> Enum.sort()
      [:with_creator, :with_media, :with_object_more, :with_reply_to]

      iex> filters = %{feed_name: "unknown"}
      iex> preloads_from_filters(filters) |> Enum.sort()
      [
        :with_creator,
        :with_media,
        :with_object_more,
        :with_peered,
        :with_reply_to,
        :with_subject
      ]

  """
  def preloads_from_filters(feed_filters) when is_map(feed_filters) do
    preloads_from_filters_rules()
    |> find_matching_rules(feed_filters)
    |> merge_rules()
    |> apply_exclusions()
    |> Enum.sort()
  end

  defp find_matching_rules(rules, feed_filters) do
    Enum.filter(rules, fn {_name, %{match: rule_match}} ->
      matches_filter?(rule_match, feed_filters)
    end)
  end

  @doc """
  Match feed filters against rule criteria.

  ## Examples

      iex> matches_filter?(%{types: "*"}, %{types: "post"})
      true
      
      iex> matches_filter?(%{types: ["post", "comment"]}, %{types: ["comment", "reaction"]})
      true
      
      iex> matches_filter?(%{types: "post"}, %{types: ["comment", "post"]})
      true
      
      iex> matches_filter?(%{types: :post}, %{types: ["comment", "post"]})
      true
      
      iex> matches_filter?(%{types: "post"}, %{types: [:comment, :post]})
      true
      
      iex> matches_filter?(%{types: ["post"]}, %{types: "post"})
      true
      
      iex> matches_filter?(%{types: "post"}, %{types: "comment"})
      false
      
      iex> matches_filter?(%{types: :post}, %{types: "post"})
      true
  """
  def matches_filter?(rule_match_criteria, feed_filters) do
    Enum.all?(rule_match_criteria, fn {key, rule_value} ->
      with filter_value <- ed(feed_filters, key, nil) do
        cond do
          is_nil(rule_value) and is_nil(filter_value) ->
            true

          is_nil(filter_value) ->
            false

          # Wildcard match
          rule_value == "*" ->
            true

          # Direct match 
          filter_value == rule_value ->
            true

          # Both are lists - check for any intersection
          is_list(rule_value) and is_list(filter_value) ->
            rule_set = MapSet.new(rule_value, &normalize_value/1)
            filter_set = MapSet.new(filter_value, &normalize_value/1)
            not MapSet.disjoint?(rule_set, filter_set)

          # Rule is list, filter is single - check membership
          is_list(rule_value) ->
            MapSet.new(rule_value, &normalize_value/1)
            |> MapSet.member?(normalize_value(filter_value))

          # Filter is list, rule is single - check membership
          is_list(filter_value) ->
            MapSet.new(filter_value, &normalize_value/1)
            |> MapSet.member?(normalize_value(rule_value))

          # String equality after normalization
          true ->
            normalize_value(filter_value) == normalize_value(rule_value)
        end
      end
    end)
  end

  # Helper to normalize values to strings for comparison
  defp normalize_value(value) when is_binary(value), do: value
  defp normalize_value(value), do: to_string(value)

  defp merge_rules([]), do: %{include: [], exclude: []}

  defp merge_rules(rules) do
    Enum.reduce(rules, %{include: [], exclude: []}, fn {_name, rule}, acc ->
      %{
        include: acc.include ++ Map.get(rule, :include, []),
        exclude: acc.exclude ++ Map.get(rule, :exclude, [])
      }
    end)
  end

  defp apply_exclusions(%{include: includes, exclude: excludes}) do
    includes
    |> MapSet.new()
    |> MapSet.difference(MapSet.new(excludes))
    |> MapSet.to_list()
  end

  def preload_presets do
    Config.get(
      [__MODULE__, :preload_presets],
      []
    )
  end

  @doc """
  Maps high-level preload keys to their corresponding detailed preload lists.

  ## Examples

      # Single preload key
      iex> map_activity_preloads([:feed]) |> Enum.sort()
      [
        :with_creator,
        :with_media,
        :with_object_more,
        :with_replied,
        :with_subject
      ]

      # Multiple preload keys
      iex> map_activity_preloads([:feed, :notifications]) |> Enum.sort()
      [
        :with_creator,
        :with_media,
        :with_object_more,
        :with_replied,
        :with_reply_to,
        :with_seen,
        :with_subject
      ]

      # With :all key it includes all defined preloads
      iex> map_activity_preloads([:all]) |> Enum.sort()
      [
        :maybe_with_labelled,
        :with_creator,
        :with_media,
        :with_object_more,
        :with_object_posts,
        :with_parent,
        :with_replied,
        :with_reply_to,
        :with_seen,
        :with_subject,
        :with_thread_name
      ]

      # With unknown key 
      iex> map_activity_preloads([:unknown_key])
      [:unknown_key]

      # Empty list returns empty list
      iex> map_activity_preloads([])
      []

      # Removes duplicates when preload lists overlap
      iex> map_activity_preloads([:posts, :posts_with_thread]) |> Enum.sort()
      [
        :with_object_posts,
        :with_replied,
        :with_subject,
        :with_thread_name
      ]
  """
  def map_activity_preloads(preloads, preload_presets \\ preload_presets())

  def map_activity_preloads(preloads, preload_presets)
      when (is_list(preloads) and is_list(preload_presets)) or is_map(preload_presets) do
    if Enum.member?(preloads, :all) do
      Enums.fun(preload_presets, :keys)
    else
      preloads
    end
    |> do_map_preloads(preload_presets, MapSet.new())
  end

  defp do_map_preloads(preloads, mappings, seen) when is_list(preloads) do
    preloads
    |> Enum.flat_map(fn preload ->
      if MapSet.member?(seen, preload) do
        # Prevent infinite recursion
        []
      else
        case ed(mappings, preload, nil) do
          expanded when is_list(expanded) ->
            # Add current preload to seen set to prevent cycles
            seen = MapSet.put(seen, preload)
            # Recursively expand any mapped keys in the result
            do_map_preloads(expanded, mappings, seen)

          _ ->
            # Not a mapped key, return as-is
            [preload]
        end
      end
    end)
    |> Enum.uniq()
  end
end
