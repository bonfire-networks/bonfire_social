defmodule Bonfire.Social.Integration do

  alias Bonfire.Common.Config

  def repo, do: Config.get!(:repo_module)

  def mailer, do: Config.get!(:mailer_module)

  def ap_publish(verb, thing_id, user_id) do
    if Bonfire.Common.Utils.module_enabled?(Bonfire.Federate.ActivityPub.APPublishWorker) do
      Bonfire.Federate.ActivityPub.APPublishWorker.enqueue(verb, %{
        "context_id" => thing_id,
        "user_id" => user_id
      })
    end

    :ok
  end

  def maybe_index(object) do
    if Config.module_enabled?(Bonfire.Search.Indexer) do
      Bonfire.Search.Indexer.maybe_index_object(object)
    else
      :ok
    end
  end

  def indexing_format_tags(obj) do
    if Config.module_enabled?(Bonfire.Tag.Tags) do
      repo().maybe_preload(obj, tags: [:profile])
      |> Map.get(:tags, [])
      |> Enum.map(&Bonfire.Tag.Tags.indexing_object_format_name/1)
    end
  end

end
