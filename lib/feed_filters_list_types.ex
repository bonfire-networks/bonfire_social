# TODO: put these somewhere more reusable
defmodule Bonfire.Social.FeedFilters.Atom do
  @moduledoc """
  Custom Type to support `:atom` fields in Ecto schemas.

  ## Example

      defmodule Post do
        use Ecto.Schema
        
        schema "posts" do
          field :atom_field, Ecto.Atom
        end
      end
  """

  @behaviour Ecto.Type

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def cast(value) when is_atom(value), do: {:ok, value}

  def cast(value) when is_binary(value) do
    try do
      {:ok, String.to_existing_atom(value)}
    rescue
      ArgumentError -> :error
    end
  end

  def cast(_), do: :error

  @impl Ecto.Type
  def load(value) when is_binary(value) do
    try do
      {:ok, String.to_existing_atom(value)}
    rescue
      ArgumentError -> :error
    end
  end

  @impl Ecto.Type
  def dump(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  def dump(_), do: :error

  # Callbacks added in newer Ecto versions

  @impl Ecto.Type
  def embed_as(_), do: :self

  @impl Ecto.Type
  def equal?(a, b), do: a == b
end

defmodule Bonfire.Social.FeedFilters.StringList do
  use Ecto.Type
  alias Bonfire.Common.Enums

  def type, do: :array

  # Cast when value is already a list
  def cast(value) when is_list(value) do
    case Enum.all?(value, fn x -> is_binary(x) or is_map(x) end) do
      true -> {:ok, Enum.map(value, &normalize_value/1) |> Enum.uniq()}
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
  def cast(values) when is_list(values) do
    case Enum.all?(values, fn x -> is_binary(x) or is_atom(x) or is_map(x) end) do
      true -> {:ok, Enum.map(values, &normalize_value/1) |> Enum.uniq()}
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
