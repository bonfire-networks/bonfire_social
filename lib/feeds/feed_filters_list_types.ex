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

  @doc """
  Casts a value to an atom.

  ## Examples

      iex> Bonfire.Social.FeedFilters.Atom.cast(:my_atom)
      {:ok, :my_atom}

      iex> Bonfire.Social.FeedFilters.Atom.cast("existing_atom")
      {:ok, :existing_atom}
      
      iex> Bonfire.Social.FeedFilters.Atom.cast("a_non_existing_atom")
      :error
      
      iex> Bonfire.Social.FeedFilters.Atom.cast(123)
      :error

  Note: The "existing_atom" test will pass because :existing_atom is already used in this file.
  """
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

  @doc """
  Loads an atom from database storage (stored as string).

  ## Examples

      iex> Bonfire.Social.FeedFilters.Atom.load("existing_atom")
      {:ok, :existing_atom}
      
      iex> Bonfire.Social.FeedFilters.Atom.load("another_non_existing_atom")
      :error
      
      iex> Bonfire.Social.FeedFilters.Atom.load(123)
      :error

  Note: The "existing_atom" test will pass because :existing_atom is already used in this file.
  """
  @impl Ecto.Type
  def load(value) when is_binary(value) do
    try do
      {:ok, String.to_existing_atom(value)}
    rescue
      ArgumentError -> :error
    end
  end

  def load(_), do: :error

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

  @doc """
  Casts a value to a list of strings.

  ## Examples

      iex> Bonfire.Social.FeedFilters.StringList.cast(["a", "b"])
      {:ok, ["a", "b"]}
      
      iex> Bonfire.Social.FeedFilters.StringList.cast("single_item")
      {:ok, ["single_item"]}
      
      iex> Bonfire.Social.FeedFilters.StringList.cast([%{id: "123"}, %{id: "456"}])
      {:ok, ["123", "456"]}
      
      iex> Bonfire.Social.FeedFilters.StringList.cast(%{id: "789"})
      {:ok, ["789"]}
      
      iex> Bonfire.Social.FeedFilters.StringList.cast(["a", "a", "b"])
      {:ok, ["a", "b"]}
      
      iex> Bonfire.Social.FeedFilters.StringList.cast([1, 2, 3])
      :error
      
      iex> Bonfire.Social.FeedFilters.StringList.cast(123)
      :error
  """
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

  @doc """
  Loads a list of strings from database storage.

  ## Examples

      iex> Bonfire.Social.FeedFilters.StringList.load(["item1", "item2"])
      {:ok, ["item1", "item2"]}
      
      iex> Bonfire.Social.FeedFilters.StringList.load("not_a_list")
      :error
  """
  # Handle loading from the database (assuming stored as strings)
  def load(values) when is_list(values) do
    {:ok, values}
  end

  def load(_), do: :error

  @doc """
  Dumps a list of strings for database storage.

  ## Examples

      iex> Bonfire.Social.FeedFilters.StringList.dump(["item1", "item2"])
      {:ok, ["item1", "item2"]}
      
      iex> Bonfire.Social.FeedFilters.StringList.dump("not_a_list")
      :error
  """
  def dump(value) when is_list(value) do
    {:ok, Enum.map(value, &to_string/1)}
  end

  def dump(_), do: :error

  # Private helper to normalize values
  defp normalize_value(value) when is_map(value), do: Enums.id(value)
  defp normalize_value(value) when is_binary(value), do: value
end

defmodule Bonfire.Social.FeedFilters.AtomOrStringList do
  use Ecto.Type
  alias Bonfire.Common.Enums
  alias Bonfire.Common.Types

  def type, do: :array

  @doc """
  Casts a value to a list of atoms or strings.

  ## Examples

      iex> Bonfire.Social.FeedFilters.AtomOrStringList.cast([:atom1, :atom2])
      {:ok, [:atom1, :atom2]}
      
      iex> Bonfire.Social.FeedFilters.AtomOrStringList.cast(["string1", "string2"])
      {:ok, [:string1, :string2]}
      
      iex> Bonfire.Social.FeedFilters.AtomOrStringList.cast([%{id: "789"}, :atom3])
      {:ok, ["789", :atom3]}
      
      iex> Bonfire.Social.FeedFilters.AtomOrStringList.cast("single_string")
      {:ok, [:single_string]}
      
      iex> Bonfire.Social.FeedFilters.AtomOrStringList.cast(:single_atom)
      {:ok, [:single_atom]}
      
      iex> Bonfire.Social.FeedFilters.AtomOrStringList.cast(%{id: "object_id"})
      {:ok, ["object_id"]}
      
      iex> Bonfire.Social.FeedFilters.AtomOrStringList.cast([123])
      :error
      
      iex> Bonfire.Social.FeedFilters.AtomOrStringList.cast(123)
      :error
  """
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

  @doc """
  Loads a list of atoms/strings from database storage.

  ## Examples

      iex> Bonfire.Social.FeedFilters.AtomOrStringList.load(["item1", "existing_atom"])
      {:ok, [:item1, :existing_atom]}
      
      iex> Bonfire.Social.FeedFilters.AtomOrStringList.load("not_a_list")
      :error

  Note: Strings that match existing atoms will be converted to atoms.
  """
  # Handle loading from the database (assuming stored as strings)
  def load(value) when is_list(value) do
    {:ok, Enum.map(value, &normalize_value/1)}
  end

  def load(_), do: :error

  @doc """
  Dumps a list of atoms/strings for database storage.

  ## Examples

      iex> Bonfire.Social.FeedFilters.AtomOrStringList.dump([:atom, "string"])
      {:ok, ["atom", "string"]}
      
      iex> Bonfire.Social.FeedFilters.AtomOrStringList.dump("not_a_list")
      :error
  """
  def dump(value) when is_list(value) do
    {:ok, Enum.map(value, &to_string/1)}
  end

  def dump(_), do: :error

  # Private helper to normalize values
  defp normalize_value(value) when is_binary(value), do: Types.maybe_to_atom(value)
  defp normalize_value(value) when is_map(value), do: Enums.id(value)
  defp normalize_value(value) when is_atom(value), do: value
end
