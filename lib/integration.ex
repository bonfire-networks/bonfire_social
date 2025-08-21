defmodule Bonfire.Social do
  @moduledoc "./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()

  use Arrows
  use Bonfire.Common.Config
  use Bonfire.Common.Utils
  require Ecto.Query
  # alias Bonfire.Data.Social.Follow
  import Untangle

  declare_extension("Social",
    icon: "ph:rss-simple-duotone",
    # emoji: "📰",
    description: l("Basic social networking functionality, such as feeds and discussions.")
  )

  @automod_id "1FR1END1YAVT0M0DERAT0RB0TS"
  def automod_id, do: @automod_id

  def get_or_create_automod,
    do:
      maybe_apply(Bonfire.Me.Users, :get_or_create_service_character, [
        automod_id(),
        "Mod Helper Bot",
        "\"Here I am, brain the size of a planet, and they ask me to read spam.\""
      ])

  @doc """
  Returns the configured repository module.

  ## Examples

      iex> Bonfire.Social.repo()
      Bonfire.Common.Repo

  """
  def repo, do: Config.repo()

  @doc """
  Returns the configured mailer module.
  """
  def mailer, do: Config.get!(:mailer_module)

  @doc """
  Federates an activity (if enabled) and wraps it with additional metadata.

  This function attempts to federate an activity and, if successful, merges the
  federated activity information with the original object.

  ## Parameters

    - subject: The subject initiating the federation.
    - object: The object to be federated.
    - opts: Optional parameters for federation.

  ## Examples

      iex> subject = %User{id: 1}
      iex> object = %Post{id: 2, content: "Hello, world!"}
      iex> {:ok, wrapped_object} = Bonfire.Social.maybe_federate_and_gift_wrap_activity(subject, object)
      iex> Map.has_key?(wrapped_object, :activity)
      true

  """
  def maybe_federate_and_gift_wrap_activity(
        subject,
        object,
        opts \\ []
      ) do
    with {:ok, ap_activity} <-
           maybe_federate_activity(subject, object, opts[:verb], opts[:object], opts)
           |> debug("result of maybe_federate_activity") do
      {:ok,
       Enums.deep_merge(object, %{
         activity: %{
           federate_activity_pub: ap_activity
         }
       })}
    else
      :ignore ->
        {:ok, object}

      other ->
        warn(other, "Unexpected result")
        other
    end
  end

  defp maybe_federate_activity(
         subject,
         activity_or_object,
         verb_override,
         object_override,
         opts
       )

  defp maybe_federate_activity(
         subject,
         %{activity: %{object: %{id: _} = inner_object} = activity} = outer_object,
         verb,
         object_override,
         opts
       ),
       # NOTE: we need the outer object for Edges like Follow or Like
       do:
         maybe_federate_activity_with_object(
           subject,
           activity,
           verb,
           object_override || outer_object,
           inner_object,
           opts
         )

  defp maybe_federate_activity(
         subject,
         %{activity: %{id: _} = activity} = activity_object,
         verb,
         object_override,
         opts
       ),
       do:
         maybe_federate_activity_with_object(
           subject,
           activity,
           verb,
           object_override,
           activity_object,
           opts
         )

  defp maybe_federate_activity(
         subject,
         %Bonfire.Data.Social.Activity{object: %{id: _} = activity_object} = activity,
         verb,
         object_override,
         opts
       ) do
    maybe_federate_activity_with_object(
      subject,
      activity,
      verb,
      object_override,
      activity_object,
      opts
    )
  end

  defp maybe_federate_activity(
         subject,
         %Bonfire.Data.Social.Activity{object: activity_object} = activity,
         verb,
         object_override,
         opts
       )
       when not is_nil(activity_object),
       do:
         repo().maybe_preload(activity, [:object, :verb])
         |> maybe_federate_activity(subject, ..., verb, object_override, opts)

  defp maybe_federate_activity(
         subject,
         %{activity: activity} = activity_object,
         verb,
         object_override,
         opts
       )
       when not is_nil(activity),
       do:
         repo().maybe_preload(activity_object, activity: [:verb])
         |> maybe_federate_activity(subject, ..., verb, object_override, opts)

  defp maybe_federate_activity(subject, activity, :delete, object, opts) do
    debug(
      object || activity,
      "Federate deletion of an object"
    )

    # FIXME: skip federate deletion for local-only objects

    # ActivityPub.delete(object || activity, true)
    maybe_federate(subject, :delete, object || activity, nil, opts)
  end

  defp maybe_federate_activity(_subject, activity, _verb, _object, _opts) do
    error(
      activity,
      "Cannot federate: Expected an Activity, or an object containing one"
    )

    # activity
  end

  defp maybe_federate_activity_with_object(
         subject,
         %Bonfire.Data.Social.Activity{} = activity,
         verb,
         object_override,
         activity_object,
         opts
       ) do
    # activity = repo().maybe_preload(activity, [:verb, :object])
    object = object_override || activity_object

    verb =
      verb ||
        e(activity, :verb, :verb, "Create")
        |> String.downcase()
        |> Types.maybe_to_atom()

    maybe_federate(subject, verb, object, activity, opts)

    # object
  end

  @doc """
  Attempts to federate an activity based on the given parameters.

  This function handles various patterns of activities and objects, attempting to
  federate them according to the specified verb and options.

  ## Parameters

    - subject: The subject initiating the federation.
    - verb: The verb describing the activity (e.g., :create, :delete).
    - object: The object to be federated.
    - activity: The associated activity data (optional).
    - opts: Additional options for federation.

  ## Examples

      iex> subject = %User{id: 1}
      iex> object = %Post{id: 2, content: "Hello, world!"}
      iex> Bonfire.Social.maybe_federate(subject, :create, object)
      {:ok, %ActivityPub.Object{}}

  """
  # TODO: clean up the following patterns
  def maybe_federate(subject, verb, object, activity \\ nil, opts \\ []) do
    debug(subject, "subject")

    if federate_outgoing?(subject) |> debug("federate_outgoing?") do
      debug(verb, "maybe prepare outgoing federation with verb...")

      Bonfire.Federate.ActivityPub.Outgoing.maybe_federate(
        subject,
        verb,
        object || e(activity, :object, nil) || e(activity, :object_id, nil),
        opts
      )
    else
      # TODO: do not enqueue if federation is disabled in Settings
      info("Federation is disabled or an adapter is not available")
      :ignore
    end
  end

  @doc """
  Checks if outgoing federation is enabled for the given subject.

  ## Parameters

    - subject: The subject to check for federation capability (optional).

  ## Examples

      iex> Bonfire.Social.federate_outgoing?()
      true

      iex> Bonfire.Social.federate_outgoing?(user)
      false

  """
  def federate_outgoing?(subject \\ nil) do
    Bonfire.Common.Extend.module_enabled?(Bonfire.Federate.ActivityPub.Outgoing, subject) and
      Bonfire.Federate.ActivityPub.Outgoing.federate_outgoing?(subject)
  end

  @doc """
  Checks if federation is generally enabled for the given subject.

  ## Parameters

    - subject: The subject to check for federation capability (optional).

  ## Examples

      iex> Bonfire.Social.federating?()
      true

      iex> Bonfire.Social.federating?(user)
      true

  """
  def federating?(subject \\ nil) do
    Bonfire.Common.Extend.module_enabled?(Bonfire.Federate.ActivityPub, subject) and
      Bonfire.Federate.ActivityPub.federating?(subject)
  end

  @doc """
  Determines if the given thing is local to the current instance.

  ## Parameters

    - thing: The object to check for locality.
    - opts: Additional options for the check (optional).

  ## Examples

      iex> Bonfire.Social.is_local?(local_user)
      true

      iex> Bonfire.Social.is_local?(remote_user)
      false

  """
  def is_local?(thing, opts \\ []) do
    maybe_apply(Bonfire.Federate.ActivityPub.AdapterUtils, :is_local?, [thing, opts], opts)
  end

  @doc """
  Executes a query and returns results based on the specified options.

  This function can return query results in various formats, including raw query,
  stream, or paginated results.

  ## Parameters

    - query: The Ecto query to execute.
    - paginate?: Boolean indicating whether to paginate results.
    - opts: Additional options for query execution.

  ## Examples

      iex> query = from(u in User, where: u.age > 18)
      iex> Bonfire.Social.many(query, false, return: :query)
      #Ecto.Query<...>

      iex> Bonfire.Social.many(query, true, after: "1")
      %{entries: [%User{}, ...], page_info: %{...}}

  """
  def many(query, paginate?, opts \\ [])

  def many(query, paginate?, opts) do
    case opts[:return] do
      # :query -> # NOTE: let repo module handle this
      #   query

      :stream ->
        many_stream(query, opts)

      _ ->
        if paginate? == false do
          repo().many(query, opts)
        else
          repo().many_paginated(query, opts)
        end
    end
  end

  def many_stream(query, opts) do
    case opts[:stream_callback] do
      nil ->
        stream = repo().stream(query, max_rows: opts[:max_rows] || 100)

        repo().transact(fn ->
          Enum.to_list(stream)
        end)

      callback ->
        repo().transaction(
          fn ->
            callback.(
              query
              |> Ecto.Query.exclude(:preload)
              |> maybe_only_id(opts)
              |> repo().stream(max_rows: opts[:max_rows] || 100)
            )
          end,
          #   1h
          timeout: opts[:timeout] || 3_600_000
        )
    end
  end

  defp maybe_only_id(query, opts) do
    if opts[:select_only_activity_id] do
      query
      |> Ecto.Query.exclude(:select)
      |> Ecto.Query.select([activity: activity], activity.id)
    else
      query
    end
  end

  def maybe_can?(context, verb, object, object_boundary \\ nil) do
    current_user_id(context) ==
      (e(object, :created, :creator_id, nil) ||
         e(object, :created, :creator, :id, nil) ||
         e(object, :creator, :id, nil) ||
         e(object, :creator_id, nil)) or
      (Bonfire.Boundaries.can?(context, verb, object_boundary) ||
         Bonfire.Boundaries.can?(context, verb, :instance))
  end
end
