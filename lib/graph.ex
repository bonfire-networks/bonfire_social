defmodule Bonfire.Social.Graph do
  use GenServer
  use Arrows
  use Bonfire.Common.Utils

  def maybe_applications() do
    case config() do
      false ->
        info("Skip social graph database (disabled)")
        []

      nil ->
        info("Skip social graph database (config not available)")
        []

      config ->
        [{Bolt.Sips, config}, Bonfire.Social.Graph]
    end
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], [])
  end

  def init(_) do
    apply_task(:start, &init_and_load/0)

    {:ok, nil}
  end

  def init_and_load() do
    graph_conn = graph_conn()

    case graph_conn() do
      nil ->
        nil

      graph_conn ->
        graph_conn
        |> Bolt.Sips.query("CREATE CONSTRAINT ON (n: Character) ASSERT EXISTS (n.id);
    CREATE CONSTRAINT ON (n: Character) ASSERT n.id IS UNIQUE;")

        load_from_db()
    end
  end

  def load_from_db() do
    info("Copying graph data from DB into memgraph...")

    for {type, conf} <- graph_meta() do
      fetch_fun = conf[:fetch_fun] || (&fetch_edges_standard/2)

      fetch_fun.(type, conf)
      |> debug()
      |> Enum.map(fn
        {:ok, subject, object} ->
          graph_add(subject, object, type)

        other ->
          error(other)
      end)
    end
  end

  defp fetch_edges_standard(type, conf) do
    prepare_fun = conf[:prepare_fun] || (&prepare_edges_standard/2)

    Bonfire.Common.Pointers.list_by_type!(type, [], skip_boundary_check: true, preload: false)
    |> debug()
    |> prepare_fun.(conf)
  end

  defp prepare_edges_standard(edges, _conf) do
    edges
    |> Enum.map(&e(&1, :edge, nil))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn o ->
      {:ok, e(o, :subject_id, nil), e(o, :object_id, nil)}
    end)
  end

  defp config, do: module_enabled?(Bonfire.Social.Graph) and Application.get_env(:bolt_sips, Bolt)
  defp disabled?, do: !config()

  def graph_conn() do
    # graph_conn = 
    if !disabled?(), do: Bolt.Sips.conn()

    # graph_conn
  end

  def graph_meta(_subject \\ nil) do
    # TODO: put in Settings
    [
      {Bonfire.Data.Social.Follow, [rank: 2, rel_name: "FOLLOWS"]}
    ]
    |> debug()
  end

  def graph_add(subject, object, type) do
    case graph_conn() do
      nil ->
        nil

      graph_conn ->
        graph_meta = graph_meta(subject)[type]

        "MERGE (a: Character {id: '#{id(subject)}'});
        MERGE (b: Character {id: '#{id(object)}'});
        MATCH (a: Character {id: '#{id(subject)}'}), (b: Character {id: '#{id(object)}'}) 
        MERGE (a)-[r:#{graph_meta[:rel_name] || type} {rank: #{graph_meta[:rank] || 1}}]->(b) 
        RETURN a.id, type(r), b.id;"
        |> debug()
        |> Bolt.Sips.query(graph_conn, ...)
        |> debug()
    end
  end

  def graph_remove(subject, object, type) do
    case graph_conn() do
      nil ->
        nil

      graph_conn ->
        graph_meta = graph_meta(subject)[type]

        "MATCH (a: Character {id: '#{id(subject)}'})-[r:#{graph_meta[:rel_name] || type}]->(b: Character {id: '#{id(object)}'}) 
        DELETE r;"
        |> debug()
        |> Bolt.Sips.query(graph_conn, ...)
        |> debug()
    end
  end

  def graph_distance(subject, object) do
    case graph_conn() do
      nil ->
        false

      graph_conn ->
        case "MATCH (subject:Character {id: '#{id(subject)}'}) 
        MATCH (object:Character {id: '#{id(object)}'}) 
        CALL nxalg.shortest_path_length(subject, object, 'rank') YIELD * 
        RETURN length;"
             |> debug()
             |> Bolt.Sips.query(graph_conn, ...)
             |> debug() do
          {:ok, %{records: [[length]]}} ->
            length

          other ->
            error(other)
            nil
        end
    end
  end

  def graph_distances(subject) do
    case graph_conn() do
      nil ->
        false

      graph_conn ->
        case "MATCH (subject:Character {id: '#{id(subject)}'}) 
        CALL nxalg.shortest_path_length(subject, NULL, 'rank') YIELD * 
        RETURN target.id, length ORDER BY length;"
             |> debug()
             |> Bolt.Sips.query(graph_conn, ...)
             |> debug() do
          {:ok, %{records: [[length]]}} ->
            length

          other ->
            error(other)
            nil
        end
    end
  end

  def graph_clear() do
    case graph_conn() do
      nil ->
        nil

      graph_conn ->
        Bolt.Sips.query(graph_conn, "MATCH (n) DETACH DELETE n;")
        |> debug()
    end
  end
end
