defmodule Bonfire.Social.APActivities do

  alias Bonfire.Federate.ActivityPub.APPublishWorker
  import Bonfire.Social.Integration

  def publish(subject, verb, object) when is_binary(object) and not is_nil(object) do
    subject = repo().preload(subject, :peered)
    do_publish(subject, verb, %{id: object})
  end

  def publish(subject, verb, object) when not is_nil(object) do
    subject = repo().preload(subject, :peered)
    do_publish(subject, verb, object)
  end

  def publish(_, _, _), do: :ignored

  def do_publish(%{peered: nil}, verb, object) do
    APPublishWorker.enqueue(verb, %{"context_id" => object.id})
  end

  def do_publish(_, _, _), do: :ignored
end
