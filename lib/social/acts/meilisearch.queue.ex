defmodule Bonfire.Social.Acts.MeiliSearch.Queue do
  @moduledoc """
  An act that enqueues publish/update/delete requests to meilisearch via an oban job queue.
  """

  alias Bonfire.Epics
  alias Bonfire.Epics.{Act, Epic}
  alias Ecto.Changeset
  alias Bonfire.Social.Integration
  import Epics
  use Arrows
  require Logger

  def index(epic) do
    Epic.update(epic, __MODULE__, [], &[:index | &1])
  end

  def unindex(epic, thing) do
    Epic.update(epic, __MODULE__, [], &[:unindex | &1])
  end

  @doc false # see module documentation
  def run(epic, act) do
    on = Keyword.get(act.options, :on, :post)
    object = epic.assigns[on]

    if epic.errors != [] do
      maybe_debug(epic, act, length(epic.errors), "Skipping due to epic errors")
    else
      work = Map.get(epic.assigns, __MODULE__, [])
      for action <- work do
        case action do
          :index   ->
            maybe_debug(epic, act, :index, "Submitting action")
            # maybe_debug(epic, act, object, "Non-formated object")
            object |> to_indexable() |> Integration.maybe_index()
          :unindex ->
            maybe_debug(epic, act, :unindex, "Submitting action")
            Integration.maybe_unindex(object)
        end
      end
    end
    epic
  end


  def to_indexable(object_or_activity_or_changeset, options \\ [])
  def to_indexable(thing, options) do
    case thing do
      # %{activities: [%{object: %{id: _} = object} = activity]} -> maybe_indexable_object(activity, object, options)
      # %{activities: [%{id: _} = activity]} -> maybe_indexable_object(activity, thing, options)
      # %{activity: %{object: %{id: _} = object}} -> maybe_indexable_object(thing.activity, object, options)
      # %{activity: %{id: _}} -> maybe_indexable_object(thing.activity, thing, options)
      # %Activity{object: %{id: _} = object} -> maybe_indexable_object(thing, object, options)
      %Changeset{} ->
        case Changeset.apply_action(thing, :insert) do
          {:ok, thing} -> to_indexable(thing, options)
          {:error, error} ->
            Logger.error("MeiliSearch.Queue: Got error applying an action to changeset: #{error}")
            nil
        end
      %{id: _} ->
        thing
        |> Bonfire.Social.Activities.activity_under_object()
        |> maybe_indexable_object()
      _ ->
        Logger.error("MeiliSearch.Queue: no clause match for function to_indexable/2")
        IO.inspect(thing, label: "thing")
        nil
    end
  end

  def maybe_indexable_object(object) do
    if Bonfire.Common.Extend.module_enabled?(Bonfire.Search.Indexer), do: Bonfire.Search.Indexer.maybe_indexable_object(object)
  end

end
