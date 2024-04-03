defmodule Bonfire.Social.Integration do
  use Arrows
  alias Bonfire.Common.Config
  use Bonfire.Common.Utils
  # alias Bonfire.Data.Social.Follow
  import Untangle

  declare_extension("Social",
    icon: "ph:rss-simple-bold",
    # emoji: "📰",
    description: l("Basic social networking functionality, such as feeds and discussions.")
  )

  def repo, do: Config.repo()

  def mailer, do: Config.get!(:mailer_module)

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
        Utils.e(activity, :verb, :verb, "Create")
        |> String.downcase()
        |> Types.maybe_to_atom()

    maybe_federate(subject, verb, object, activity, opts)

    # object
  end

  # TODO: clean up the following patterns

  def maybe_federate(subject, verb, object, activity \\ nil, opts \\ []) do
    debug(subject, "subject")

    if federate_outgoing?(subject) |> debug("federate_outgoing?") do
      debug(verb, "maybe prepare outgoing federation with verb...")

      Bonfire.Federate.ActivityPub.Outgoing.maybe_federate(
        subject,
        verb,
        object || Utils.e(activity, :object, nil) || Utils.e(activity, :object_id, nil),
        opts
      )
    else
      # TODO: do not enqueue if federation is disabled in Settings
      info("Federation is disabled or an adapter is not available")
      :ignore
    end
  end

  def federate_outgoing?(subject \\ nil) do
    Bonfire.Common.Extend.module_enabled?(Bonfire.Federate.ActivityPub.Outgoing, subject) and
      Bonfire.Federate.ActivityPub.Outgoing.federate_outgoing?(subject)
  end

  def federating?(subject \\ nil) do
    Bonfire.Common.Extend.module_enabled?(Bonfire.Federate.ActivityPub, subject) and
      Bonfire.Federate.ActivityPub.federating?(subject)
  end

  def is_local?(thing, opts \\ []) do
    if Bonfire.Common.Extend.module_enabled?(Bonfire.Federate.ActivityPub.AdapterUtils) do
      Bonfire.Federate.ActivityPub.AdapterUtils.is_local?(thing, opts)
    else
      # if activitypub is disabled, it must be?
      true
    end
  end

  def many(query, paginate?, opts \\ [])

  def many(query, false, opts) do
    case opts[:return] do
      :query ->
        query

      :stream ->
        repo().transaction(
          fn ->
            opts[:stream_callback].(
              repo().stream(Ecto.Query.exclude(query, :preload), max_rows: 100)
            )
          end,
          #   1h
          timeout: 3_600_000
        )

      _ ->
        repo().many(query, opts)
    end
  end

  def many(query, _true, opts) do
    case opts[:return] do
      # :query ->
      #   query

      # :csv ->
      # query
      _ ->
        repo().many_paginated(query, opts)
    end
  end
end
