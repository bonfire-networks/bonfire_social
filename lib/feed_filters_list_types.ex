defmodule Bonfire.Social.FeedFilters.StringList do
  use Ecto.Type
  alias Bonfire.Common.Enums

  def type, do: :array

  # Cast when value is already a list
  def cast(value) when is_list(value) do
    case Enum.all?(value, fn x -> is_binary(x) or is_map(x) end) do
      true -> {:ok, Enum.map(value, &normalize_value/1)}
      false -> :error
    end
  end

  # Cast when value is a single item
  def cast(value) when is_binary(value) or is_map(value) do
    {:ok, [normalize_value(value)]}
  end

  def cast(_), do: :error

  # Handle loading from the database (assuming stored as strings)
  def load(values) when is_list(values) do
    {:ok, values}
  end

  def dump(value) when is_list(value) do
    {:ok, Enum.map(value, &to_string/1)}
  end

  # Private helper to normalize values
  defp normalize_value(value) when is_map(value), do: Enums.id(value)
  defp normalize_value(value) when is_binary(value), do: value
end

defmodule Bonfire.Social.FeedFilters.AtomOrStringList do
  use Ecto.Type
  alias Bonfire.Common.Enums
  alias Bonfire.Common.Types

  def type, do: :array

  # Cast when value is already a list
  def cast(value) when is_list(value) do
    case Enum.all?(value, fn x -> is_binary(x) or is_atom(x) or is_map(x) end) do
      true -> {:ok, Enum.map(value, &normalize_value/1)}
      false -> :error
    end
  end

  # Cast when value is a single item
  def cast(value) when is_binary(value) or is_atom(value) or is_map(value) do
    {:ok, [normalize_value(value)]}
  end

  def cast(_), do: :error

  # Handle loading from the database (assuming stored as strings)
  def load(value) when is_list(value) do
    {:ok, Enum.map(value, &normalize_value/1)}
  end

  def dump(value) when is_list(value) do
    {:ok, Enum.map(value, &to_string/1)}
  end

  # Private helper to normalize values
  defp normalize_value(value) when is_binary(value), do: Types.maybe_to_atom(value)
  defp normalize_value(value) when is_map(value), do: Enums.id(value)
  defp normalize_value(value) when is_atom(value), do: value
end
