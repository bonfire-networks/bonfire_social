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


  def ap_push_activity(subject, activity_or_object, verb_override \\ nil, object_override \\ nil)

  def ap_push_activity(
        subject,
        %{activity: %{object: %{id: _} = inner_object} = activity} = outer_object,
        verb,
        object_override
      ), # NOTE: we need the outer object for Edges like Follow or Like
      do: ap_push_activity_with_object(subject, activity, verb, object_override || outer_object, inner_object) |> info

  def ap_push_activity(
        subject,
        %{activity: %{id: _} = activity} = activity_object,
        verb,
        object_override
      ),
      do: ap_push_activity_with_object(subject, activity, verb, object_override, activity_object)

  def ap_push_activity(
        subject,
        %Bonfire.Data.Social.Activity{object: %{id: _} = activity_object} = activity,
        verb,
        object_override
      ) do
    ap_push_activity_with_object(subject, activity, verb, object_override, activity_object)
  end

  def ap_push_activity(subject, %Bonfire.Data.Social.Activity{object: activity_object} = activity, verb, object_override) when not is_nil(activity_object),
    do:
      repo().maybe_preload(activity, [:object, :verb])
      |> ap_push_activity(subject, ..., verb, object_override)

  def ap_push_activity(subject, %{activity: activity} = activity_object, verb, object_override) when not is_nil(activity),
    do:
      repo().maybe_preload(activity_object, activity: [:verb])
      |> ap_push_activity(subject, ..., verb, object_override)

  def ap_push_activity(_subject_id, activity, _verb, _object) do
    error(
      activity,
      "Cannot federate: Expected an Activity, or an object containing one"
    )

    # activity
  end

  defp ap_push_activity_with_object(
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
        |> String.to_existing_atom()

    activity_ap_publish(subject, verb, object, activity)

    # object
  end

  # TODO: clean up the following patterns

  defp activity_ap_publish(subject, verb, object, activity) when verb in [:create, "create"] do
    maybe_enqueue(
      "create",
      Utils.ulid(object) || Utils.e(activity, :object_id, nil),
      subject
    )
  end

  defp activity_ap_publish(subject, :update, object, activity) do
    maybe_enqueue(
      "update",
      Utils.ulid(object) || Utils.e(activity, :object_id, nil),
      subject
    )
  end

  defp activity_ap_publish(subject, :delete, object, activity) do
    maybe_enqueue(
      "delete",
      Utils.ulid(object) || Utils.e(activity, :object_id, nil),
      subject
    )
  end

  defp activity_ap_publish(subject, verb, object, activity) do
    verb = to_string(verb || "create")
    info(verb, "outgoing federation verb")

    maybe_enqueue(
      verb,
      Utils.ulid(object) || Utils.e(activity, :object_id, nil),
      subject
    )
  end

  defp maybe_enqueue(verb, thing, subject) do
      if Bonfire.Common.Extend.module_enabled?(
          Bonfire.Federate.ActivityPub.APPublishWorker,
          subject
        ) do

        Bonfire.Federate.ActivityPub.APPublishWorker.maybe_enqueue(verb, thing, subject)

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
