defmodule Bonfire.Social.Integration do
  use Arrows
  alias Bonfire.Common.Config
  alias Bonfire.Common.Utils
  require Logger

  def repo, do: Config.get!(:repo_module)

  def mailer, do: Config.get!(:mailer_module)

  def ap_push_activity(subject_id, activity, verb \\ nil)
  def ap_push_activity(subject_id, %{activity: %{id: _} = activity} = _object, verb), do: ap_push_activity(subject_id, activity, verb)
  def ap_push_activity(subject_id, %Bonfire.Data.Social.Activity{} = activity, verb) do
    verb = verb || repo().maybe_preload(activity, :verb) |> Utils.e(:verb, :verb, "Create") |> String.downcase |> String.to_existing_atom
    activity_ap_publish(subject_id, verb, activity)
    activity
  end
  def ap_push_activity(subject_id, %{activity: %{}} = object, verb), do: repo().maybe_preload(object, activity: [:verb]) |> ap_push_activity(subject_id, ..., verb)

  def activity_ap_publish(subject_id, :create, activity) do
    ap_publish("create", activity.object_id, subject_id)
  end

  def activity_ap_publish(subject_id, :follow, activity) do
    follow = Bonfire.Social.Follows.get!(subject_id, activity.object_id, skip_boundary_check: true)
    ap_publish("create", follow.id, subject_id)
  end

  def activity_ap_publish(subject_id, :like, activity) do
    like = Bonfire.Social.Likes.get!(activity.subject, activity.object_id)
    ap_publish("create", like.id, subject_id)
  end

  def activity_ap_publish(subject_id, :boost, activity) do
    boost = Bonfire.Social.Boosts.get!(activity.subject, activity.object)
    ap_publish("create", boost.id, subject_id)
  end

  def activity_ap_publish(_, verb, _) do
    Logger.warn("unhandled outgoing federation verb: #{verb}")
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

  def check_local(thing) do
    if Bonfire.Common.Utils.module_enabled?(Bonfire.Federate.ActivityPub.Utils) do
      Bonfire.Federate.ActivityPub.Utils.check_local(thing)
    end
  end

  def maybe_index(object) do
    if Config.module_enabled?(Bonfire.Search.Indexer) do
      Bonfire.Search.Indexer.maybe_index_object(object)
    else
      :ok
    end
  end


end
