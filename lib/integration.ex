defmodule Bonfire.Social.Integration do

  alias Bonfire.Common.Config

  def repo, do: Config.get!(:repo_module)

  def mailer, do: Config.get!(:mailer_module)


  def maybe_index(object) do
    if Config.module_enabled?(Bonfire.Search.Indexer) do
      Bonfire.Search.Indexer.maybe_index_object(object)
    else
      :ok
    end
  end

end
