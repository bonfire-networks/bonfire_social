defmodule Bonfire.Social.Integration do
  use Arrows
  alias Bonfire.Common.Config
  alias Bonfire.Common.Utils
  import Where

  def repo, do: Config.get!(:repo_module)

  def mailer, do: Config.get!(:mailer_module)

  # This should return the same type it accepts
  def ap_push_activity(subject_id, activity, verb \\ nil, object \\ nil)
  def ap_push_activity(%{id: subject_id}, activity, verb, object ), do: ap_push_activity(subject_id, activity, verb, object )
  def ap_push_activity(subject_id, %{activity: %{id: _} = activity} = object, verb, _object ), do: ap_push_activity_with_object(subject_id, activity, verb, object)
  def ap_push_activity(subject_id, %Bonfire.Data.Social.Activity{} = activity, verb, object) do
    ap_push_activity_with_object(subject_id, activity, verb, object)
    activity
  end
  def ap_push_activity(subject_id, %{activity: %{}} = object, verb, _object), do: repo().maybe_preload(object, activity: [:verb]) |> ap_push_activity(subject_id, ..., verb, object)

  def ap_push_activity_with_object(subject_id, %Bonfire.Data.Social.Activity{} = activity, verb, object) do
    activity = repo().maybe_preload(activity, [:verb, :object])
    verb = verb || Utils.e(activity, :verb, :verb, "Create") |> String.downcase |> String.to_existing_atom
    activity_ap_publish(subject_id, verb, object || activity.object, activity)
    object
  end

  # TODO: clean up the following patterns

  def activity_ap_publish(subject_id, :create, _object, activity) do
    ap_publish("create", activity.object_id, subject_id)
  end

  def activity_ap_publish(subject_id, :follow, _object, activity) do
    follow = Bonfire.Social.Follows.get!(subject_id, activity.object_id, skip_boundary_check: true)
    ap_publish("create", follow.id, subject_id)
  end

  def activity_ap_publish(subject_id, :like, _object, activity) do
    like = Bonfire.Social.Likes.get!(activity.subject, activity.object_id)
    ap_publish("create", like.id, subject_id)
  end

  def activity_ap_publish(subject_id, :boost, _object, activity) do
    boost = Bonfire.Social.Boosts.get!(activity.subject, activity.object)
    ap_publish("create", boost.id, subject_id)
  end

  def activity_ap_publish(subject_id, :request, object, activity) do
    # dump(object)
    # dump(activity)
    # FIXME: we're just assuming that all requests are for follow for now
    request = Bonfire.Social.Requests.get!(activity.subject, Follow, object || activity.object)
    ap_publish("create", request.id, subject_id)
  end

  def activity_ap_publish(_, verb, _, _) do
    warn("unhandled outgoing federation verb: #{inspect verb}")
  end

  def ap_publish(verb, thing_id, user_id) do
    if Bonfire.Common.Utils.module_enabled?(Bonfire.Federate.ActivityPub.APPublishWorker) do
      Bonfire.Federate.ActivityPub.APPublishWorker.enqueue(verb, %{
        "context_id" => thing_id,
        "user_id" => user_id
      }, unique: [period: 5])
    end

    :ok
  end

  def is_local?(thing) do
    if Bonfire.Common.Utils.module_enabled?(Bonfire.Federate.ActivityPub.Utils) do
      Bonfire.Federate.ActivityPub.Utils.is_local?(thing)
    end
  end

  def maybe_index(object) do
    if Config.module_enabled?(Bonfire.Search.Indexer) do
      Bonfire.Search.Indexer.maybe_index_object(object)
    else
      :ok
    end
  end

  def maybe_unindex(object) do
    if Config.module_enabled?(Bonfire.Search.Indexer) do
      Bonfire.Search.Indexer.maybe_delete_object(object)
    else
      :ok
    end
  end

end
