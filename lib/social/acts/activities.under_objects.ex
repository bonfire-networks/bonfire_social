defmodule Bonfire.Social.Acts.Activities.UnderObjects do

  import Where
  alias Bonfire.Social.Activities
  alias Bonfire.Epics.{Act, Epic}
  require Act

  def run(epic, act) do
    if epic.errors == [] do
      Act.debug(epic, act, "No errors, transforming.")
      do_run(epic, act)
    else
      Act.debug(epic, act, length(epic.errors), "Skipping because of epic errors")
      epic
    end
  end

  defp do_run(epic, act) do
    Keyword.fetch!(act.options, :objects)
    |> Enum.reduce(epic, fn key, epic ->
      case key do
        _ when is_atom(key) -> do_key(epic, act, key, key)
        {dest, source} when is_atom(source) and is_atom(dest) -> do_key(epic, act, source, dest)
      end
    end)
  end

  defp do_key(epic, act, source_key, dest_key) do
    case epic.assigns[source_key] do
      nil ->
        Act.debug(epic, act, "Skipping #{dest_key} as Assigns key #{source_key} is nil")
        epic
      other ->
        Act.debug(epic, act, "Rewriting #{source_key} to #{dest_key}")
        Epic.assign(epic, dest_key, Activities.activity_under_object(other))
    end
  end

end
