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

  # This should return the same type it accepts
  def ap_push_activity(subject_id, activity, verb \\ nil, object \\ nil)

  def ap_push_activity(%{id: subject_id}, activity, verb, object),
    do: ap_push_activity(subject_id, activity, verb, object)

  def ap_push_activity(
        subject_id,
        %{activity: %{id: _} = activity} = object,
        verb,
        _object
      ),
      do: ap_push_activity_with_object(subject_id, activity, verb, object)

  def ap_push_activity(
        subject_id,
        %Bonfire.Data.Social.Activity{} = activity,
        verb,
        object
      ) do
    ap_push_activity_with_object(subject_id, activity, verb, object)
    activity
  end

  def ap_push_activity(subject_id, %{activity: %{}} = object, verb, _object),
    do:
      repo().maybe_preload(object, activity: [:verb])
      |> ap_push_activity(subject_id, ..., verb, object)

  def ap_push_activity(_subject_id, activity, _verb, _object) do
    error(
      activity,
      "Cannot federate: Expected an Activity, or an object containing one, but got"
    )

    activity
  end

  def ap_push_activity_with_object(
        subject_id,
        %Bonfire.Data.Social.Activity{} = activity,
        verb,
        object
      ) do
    activity = repo().maybe_preload(activity, [:verb, :object])

    verb =
      verb ||
        Utils.e(activity, :verb, :verb, "Create")
        |> String.downcase()
        |> String.to_existing_atom()

    activity_ap_publish(subject_id, verb, object || activity.object, activity)
    object
  end

  # TODO: clean up the following patterns

  def activity_ap_publish(subject_id, :create, object, activity) do
    ap_publish(
      "create",
      Utils.e(activity, :object_id, Utils.ulid(object)),
      subject_id
    )
  end

  def activity_ap_publish(subject_id, :update, object, activity) do
    ap_publish(
      "update",
      Utils.e(activity, :object_id, Utils.ulid(object)),
      subject_id
    )
  end

  def activity_ap_publish(subject_id, :delete, object, activity) do
    ap_publish(
      "delete",
      Utils.e(activity, :object_id, Utils.ulid(object)),
      subject_id
    )
  end

  def activity_ap_publish(subject_id, :follow, _object, activity) do
    follow =
      Bonfire.Social.Follows.get!(subject_id, activity.object_id, skip_boundary_check: true)

    ap_publish("create", follow.id, subject_id)
  end

  def activity_ap_publish(subject_id, :like, _object, activity) do
    activity = repo().preload(activity, [:subject, :object])

    like = Bonfire.Social.Likes.get!(activity.subject, activity.object, skip_boundary_check: true)

    ap_publish("create", like.id, subject_id)
  end

  def activity_ap_publish(subject_id, :boost, _object, activity) do
    activity = repo().preload(activity, [:subject, :object])

    boost =
      Bonfire.Social.Boosts.get!(activity.subject, activity.object, skip_boundary_check: true)

    ap_publish("create", boost.id, subject_id)
  end

  def activity_ap_publish(subject_id, :request, object, activity) do
    # info(object)
    # FIXME: we're just assuming that all requests are for follow for now
    activity = repo().preload(activity, [:subject, :object])

    request =
      Bonfire.Social.Requests.get!(
        activity.subject,
        Follow,
        object || activity.object,
        skip_boundary_check: true
      )

    ap_publish("create", object.id, activity.subject_id)
  end

  def activity_ap_publish(subject_id, verb, object, activity) do
    warn(verb, "unhandled outgoing federation verb (fallback to create)")

    ap_publish(
      "create",
      Utils.e(activity, :object_id, Utils.ulid(object)),
      subject_id
    )
  end

  def ap_publish(verb, thing_id, user_id) do
    if Bonfire.Common.Extend.module_enabled?(
         Bonfire.Federate.ActivityPub.APPublishWorker,
         user_id
       ) do
      Bonfire.Federate.ActivityPub.APPublishWorker.enqueue(
        verb,
        %{
          "context_id" => thing_id,
          "user_id" => user_id
        },
        unique: [period: 5]
      )
    end

    :ok
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
