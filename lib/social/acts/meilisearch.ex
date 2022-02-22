defmodule Bonfire.Social.Acts.MeiliSearch do
  @moduledoc """
  An act that enqueues publish/update/delete requests to meilisearch via an oban job queue.
  """

  alias Bonfire.Epics.{Act, Epic}
  alias Ecto.Changeset
  require Act
  use Arrows

  def index(epic, thing) do
    Epic.update(epic, __MODULE__, [], &[{:index, thing} | &1])
  end

  def unindex(epic, thing) do
    Epic.update(epic, __MODULE__, [], &[{:unindex, thing} | &1])
  end

  @doc false # see module documentation
  def run(epic, act) do
    on = act.options[:on]
    changeset = epic.assigns[on]
    if epic.errors != [] do
      Act.debug(epic, act, length(epic.errors), "Skipping due to epic errors")
    else
      work = Map.get(epic.assigns, __MODULE__, [])
      for {k, v} <- work do
        case k do
          :index   ->
            Act.debug(epic, act, "Submitting index action")
            Integration.maybe_index(v)
          :unindex ->
            Act.debug(epic, act, "Submitting unindex action")
            Integration.maybe_unindex(v)
        end
      end
    end
    epic
  end

end
