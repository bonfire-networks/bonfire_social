defmodule Bonfire.Social.Integration do
  use Arrows
  alias Bonfire.Common.Config
  use Bonfire.Common.Utils
  # alias Bonfire.Data.Social.Follow
  import Untangle

  def repo, do: Config.repo()

  def mailer, do: Config.get!(:mailer_module)

  def is_admin?(user) do
    if is_map(user) and Map.get(user, :instance_admin) do
      Map.get(user.instance_admin, :is_instance_admin)
    else
      # FIXME
      false
    end
  end

  def maybe_federate_and_gift_wrap_activity(
        subject,
        object,
        verb_override \\ nil,
        object_override \\ nil
      ) do
    with {:ok, ap_activity} <-
           maybe_federate_activity(subject, object, verb_override, object_override)
           |> debug("result of maybe_federate_activity") do
      {:ok,
       Enums.deep_merge(object, %{
         activity: %{
           federate_activity_pub: ap_activity
         }
       })}
    else
      :ignore -> {:ok, object}
      other -> other
    end
  end

  defp maybe_federate_activity(
         subject,
         activity_or_object,
         verb_override,
         object_override
       )

  defp maybe_federate_activity(
         subject,
         %{activity: %{object: %{id: _} = inner_object} = activity} = outer_object,
         verb,
         object_override
       ),
       # NOTE: we need the outer object for Edges like Follow or Like
       do:
         maybe_federate_activity_with_object(
           subject,
           activity,
           verb,
           object_override || outer_object,
           inner_object
         )

  defp maybe_federate_activity(
         subject,
         %{activity: %{id: _} = activity} = activity_object,
         verb,
         object_override
       ),
       do:
         maybe_federate_activity_with_object(
           subject,
           activity,
           verb,
           object_override,
           activity_object
         )

  defp maybe_federate_activity(
         subject,
         %Bonfire.Data.Social.Activity{object: %{id: _} = activity_object} = activity,
         verb,
         object_override
       ) do
    maybe_federate_activity_with_object(subject, activity, verb, object_override, activity_object)
  end

  defp maybe_federate_activity(
         subject,
         %Bonfire.Data.Social.Activity{object: activity_object} = activity,
         verb,
         object_override
       )
       when not is_nil(activity_object),
       do:
         repo().maybe_preload(activity, [:object, :verb])
         |> maybe_federate_activity(subject, ..., verb, object_override)

  defp maybe_federate_activity(
         subject,
         %{activity: activity} = activity_object,
         verb,
         object_override
       )
       when not is_nil(activity),
       do:
         repo().maybe_preload(activity_object, activity: [:verb])
         |> maybe_federate_activity(subject, ..., verb, object_override)

  defp maybe_federate_activity(_subject_id, activity, _verb, _object) do
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
         activity_object
       ) do
    # activity = repo().maybe_preload(activity, [:verb, :object])
    object = object_override || activity_object

    verb =
      verb ||
        Utils.e(activity, :verb, :verb, "Create")
        |> String.downcase()
        |> Types.maybe_to_atom()

    maybe_federate(subject, verb, object, activity)

    # object
  end

  # TODO: clean up the following patterns

  def maybe_federate(subject, verb, object, activity \\ nil) do
    if federating?(subject) do
      info(verb, "maybe prepare outgoing federation with verb...")

      Bonfire.Federate.ActivityPub.Outgoing.maybe_federate(
        subject,
        verb,
        object || Utils.e(activity, :object, nil) || Utils.e(activity, :object_id, nil)
      )
    else
      # TODO: do not enqueue if federation is disabled in Settings
      info("Federation is disabled or an adapter is not available")
      :ignore
    end
  end

  def federating?(subject \\ nil) do
    ActivityPub.Config.federating?() and
      Bonfire.Common.Extend.module_enabled?(
        Bonfire.Federate.ActivityPub.Outgoing,
        subject
      )
  end

  def is_local?(thing) do
    if Bonfire.Common.Extend.module_enabled?(Bonfire.Federate.ActivityPub.AdapterUtils) do
      Bonfire.Federate.ActivityPub.AdapterUtils.is_local?(thing)
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
        repo().transaction(fn ->
          opts[:stream_callback].(
            repo().stream(Ecto.Query.exclude(query, :preload), max_rows: 100)
          )
        end)

      _ ->
        repo().many(query, opts)
    end
  end

  def many(query, _, opts) do
    case opts[:return] do
      :query ->
        query

      # :csv ->
      # query
      _ ->
        repo().many_paginated(query, opts[:pagination] || opts[:paginate] || opts)
    end
  end
end
