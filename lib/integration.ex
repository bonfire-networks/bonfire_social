defmodule Bonfire.Social.Integration do
  use Arrows
  alias Bonfire.Common.Config
  alias Bonfire.Common.Utils
  alias Bonfire.Data.Social.Follow
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
    {:ok,
     Utils.deep_merge(object, %{
       activity: %{
         federate_activity_pub:
           Utils.ok_unwrap(
             maybe_federate_activity(subject, object, verb_override, object_override)
           )
       }
     })}
  end

  def maybe_federate_activity(
        subject,
        activity_or_object,
        verb_override \\ nil,
        object_override \\ nil
      )

  def maybe_federate_activity(
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
        |> info

  def maybe_federate_activity(
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

  def maybe_federate_activity(
        subject,
        %Bonfire.Data.Social.Activity{object: %{id: _} = activity_object} = activity,
        verb,
        object_override
      ) do
    maybe_federate_activity_with_object(subject, activity, verb, object_override, activity_object)
  end

  def maybe_federate_activity(
        subject,
        %Bonfire.Data.Social.Activity{object: activity_object} = activity,
        verb,
        object_override
      )
      when not is_nil(activity_object),
      do:
        repo().maybe_preload(activity, [:object, :verb])
        |> maybe_federate_activity(subject, ..., verb, object_override)

  def maybe_federate_activity(
        subject,
        %{activity: activity} = activity_object,
        verb,
        object_override
      )
      when not is_nil(activity),
      do:
        repo().maybe_preload(activity_object, activity: [:verb])
        |> maybe_federate_activity(subject, ..., verb, object_override)

  def maybe_federate_activity(_subject_id, activity, _verb, _object) do
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
         activity_object \\ nil
       ) do
    # activity = repo().maybe_preload(activity, [:verb, :object])
    object = object_override || activity_object

    verb =
      verb ||
        Utils.e(activity, :verb, :verb, "Create")
        |> String.downcase()
        |> Utils.maybe_to_atom()

    maybe_federate(subject, verb, object, activity)

    # object
  end

  # TODO: clean up the following patterns

  defp maybe_federate(subject, verb, object, activity) do
    if Bonfire.Common.Extend.module_enabled?(
         Bonfire.Federate.ActivityPub.Outgoing,
         subject
       ) do
      info(verb, "maybe prepare outgoing federation with verb...")

      Bonfire.Federate.ActivityPub.Outgoing.maybe_federate(
        subject,
        verb,
        object || Utils.e(activity, :object, nil) || Utils.e(activity, :object_id, nil)
      )
    else
      # TODO: do not enqueue if federation is disabled in Settings
      info("Federation is disabled or an adapter is not available")
      :skip
    end
  end

  def is_local?(thing) do
    if Bonfire.Common.Extend.module_enabled?(Bonfire.Federate.ActivityPub.Utils) do
      Bonfire.Federate.ActivityPub.Utils.is_local?(thing)
    else
      # if activitypub is disabled, it must be?
      true
    end
  end

  def maybe_indexable_object(object) do
    if Bonfire.Common.Extend.module_enabled?(
         Bonfire.Search.Indexer,
         Utils.e(object, :creator, :id, nil) ||
           Utils.e(object, :created, :creator_id, nil)
       ),
       do:
         object
         |> Bonfire.Social.Activities.activity_under_object()
         |> Bonfire.Search.Indexer.maybe_indexable_object()
  end

  def maybe_index(object) do
    if Bonfire.Common.Extend.module_enabled?(
         Bonfire.Search.Indexer,
         Utils.e(object, :creator, :id, nil) ||
           Utils.e(object, :created, :creator_id, nil)
       ) do
      Bonfire.Search.Indexer.maybe_index_object(object)
      |> debug()
    else
      :ok
    end
  end

  def maybe_unindex(object) do
    if Bonfire.Common.Extend.module_enabled?(Bonfire.Search.Indexer) do
      Bonfire.Search.Indexer.maybe_delete_object(object)
    else
      :ok
    end
  end
end
