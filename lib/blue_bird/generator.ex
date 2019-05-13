defmodule BlueBird.Generator do
  @moduledoc """
  Generates a map containing information about the api routes.

  `BlueBird.Generator` uses the connections logged by `BlueBird.ConnLogger` and
  the functions generated by the `BlueBird.Controller.api/3` macro to generate
  a map containing all the data that is needed to generate the doc file.

  It is called when `BlueBird.Formatter` receives the `:suite_finished` event
  by `ExUnit` and immediately piped to `BlueBird.BlueprintWriter` to write
  the documentation to file.
  """
  require Logger

  alias BlueBird.{ApiDoc, ConnLogger, Request, Response, Route}
  alias Mix.Project
  alias Phoenix.Naming
  alias Phoenix.Router.Route, as: PhxRoute

  @default_url "http://localhost"
  @default_title "API Documentation"
  @default_description "Enter API description in mix.exs - blue_bird_info"

  @doc """
  Generates a map from logged connections and the `api/3` macros.

  ## Example response

      %BlueBird.ApiDoc{
        title: "The API",
        description: "Enter API description in mix.exs - blue_bird_info",
        terms_of_service: "Use on your own risk.",
        host: "http://localhost",
        contact: %{
          name: "Henry",
          url: "https://henry.something",
          email: "mail@henry.something"
        },
        license: %{
          name: "Apache 2.0",
          url: "https://www.apache.org/licenses/LICENSE-2.0"
        },
        routes: [
          %BlueBird.Route{
            description: "Gets a single user.",
            group: "Users",
            method: "GET",
            note: nil,
            parameters: [
              %BlueBird.Parameter{
                description: "ID",
                name: "id",
                type: "int"
              }
            ],
            path: "/users/:id",
            title: "Get single user",
            warning: nil,
            requests: [
              %BlueBird.Request{
                body_params: %{},
                headers: [{"accept", "application/json"}],
                method: "GET",
                path: "/user/:id",
                path_params: %{"id" => 1},
                query_params: %{},
                response: %BlueBird.Response{
                  body: "{\\"status\\":\\"ok\\"}",
                  headers: [{"content-type", "application/json"}],
                  status: 200
                }
              }
            ]
          }
        ]
      }
  """
  @spec run :: ApiDoc.t()
  def run do
    IO.puts "Running BlueBird.Generate"

    prepare_docs()
  end

  @spec prepare_docs() :: ApiDoc.t()
  defp prepare_docs() do
    config = blue_bird_config()
    router_module = Keyword.get(config, :router)
    info = blue_bird_info()
    contact = Keyword.get(info, :contact, [])
    license = Keyword.get(info, :license, [])

    %ApiDoc{
      host: Keyword.get(info, :host, @default_url),
      title: Keyword.get(info, :title, @default_title),
      description: Keyword.get(info, :description, @default_description),
      terms_of_service: Keyword.get(info, :terms_of_service, ""),
      contact: [
        name: Keyword.get(contact, :name, ""),
        url: Keyword.get(contact, :url, ""),
        email: Keyword.get(contact, :email, "")
      ],
      license: [
        name: Keyword.get(license, :name, ""),
        url: Keyword.get(license, :url, "")
      ],
      routes: generate_docs_for_routes(router_module),
      groups: generate_groups_for_routes(router_module)
    }
  end

  @spec blue_bird_info :: [String.t()]
  defp blue_bird_info do
    case function_exported?(Project.get(), :blue_bird_info, 0) do
      true -> Project.get().blue_bird_info()
      false -> []
    end
  end

  @spec generate_docs_for_routes(atom) :: [Request.t()]
  defp generate_docs_for_routes(router_module) do
    routes = filter_api_routes(router_module.__routes__)

    ConnLogger.get_conns()
    |> requests(routes)
    |> process_routes(routes)
  end

  @spec generate_groups_for_routes(atom) :: map
  defp generate_groups_for_routes(router_module) do
    router_module.__routes__
    |> filter_api_routes
    |> controllers
    |> extract_groups
  end

  @spec filter_api_routes([%PhxRoute{}]) :: [%PhxRoute{}]
  defp filter_api_routes(routes) do
    pipelines = Keyword.get(blue_bird_config(), :pipelines, [:api])

    Enum.filter(routes, fn route ->
      Enum.any?(
        pipelines,
        &Enum.member?(route.pipe_through, &1)
      )
    end)
  end

  @spec controllers([%PhxRoute{}]) :: [atom]
  defp controllers(routes) do
    routes
    |> Enum.reduce([], fn route, list ->
      [Module.concat([:"Elixir" | Module.split(route.plug)]) | list]
    end)
    |> Enum.uniq()
  end

  @spec extract_groups([module], map) :: map
  defp extract_groups(controllers, groups \\ %{})
  defp extract_groups([], groups), do: groups

  defp extract_groups([controller | list], groups) do
    %{name: name, description: description} = apply(controller, :api_group, [])

    extract_groups(
      list,
      Map.put(groups, name, description)
    )
  rescue
    UndefinedFunctionError -> extract_groups(list, groups)
  end

  @spec requests([Plug.Conn.t()], [%PhxRoute{}]) :: [Plug.Conn.t()]
  defp requests(test_conns, routes) do
    Enum.reduce(test_conns, [], fn conn, list ->
      route = find_route(routes, conn.request_path)

      [request_map(route, conn) | list]
    end)
  end

  @spec find_route([%PhxRoute{}], String.t()) :: %PhxRoute{} | nil
  defp find_route(routes, path) do
    routes
    |> Enum.sort_by(fn route -> -byte_size(route.path) end)
    |> Enum.find(fn route -> route_match?(route.path, path) end)
  end

  @spec route_match?(String.t(), String.t()) :: boolean
  defp route_match?(route, path) do
    ~r/(:[^\/]+)/
    |> Regex.replace(route, "([^/]+)")
    |> Regex.compile!()
    |> Regex.match?(path)
  end

  @spec request_map(%PhxRoute{}, %Plug.Conn{}) :: Request.t()
  defp request_map(route, conn) do
    %Request{
      method: conn.method,
      path: route.path,
      headers: filter_headers(conn.req_headers, :request),
      path_params: conn.path_params,
      body_params: conn.body_params,
      query_params: conn.query_params,
      response: %Response{
        status: conn.status,
        body: conn.resp_body,
        headers: filter_headers(conn.resp_headers, :response)
      }
    }
  end

  @spec filter_headers([{String.t(), String.t()}], atom) :: [
          {String.t(), String.t()}
        ]
  defp filter_headers(headers, type) do
    ignore_headers = get_ignore_headers(type)

    Enum.reject(headers, fn {key, value} ->
      value == "" || Enum.member?(ignore_headers, key)
    end)
  end

  @spec get_ignore_headers(atom) :: [String.t()]
  defp get_ignore_headers(type) when type == :request or type == :response do
    blue_bird_config()
    |> Keyword.get(:ignore_headers, false)
    |> case do
      [_ | _] = headers -> headers
      %{} = header_map -> Map.get(header_map, type, [])
      _ -> []
    end
  end

  @spec process_routes([Request.t()], [%PhxRoute{}]) :: [Request.t()]
  defp process_routes(requests_list, routes) do
    routes
    |> Enum.reduce([], fn route, generate_docs_for_routes ->
      case process_route(route, requests_list) do
        {:ok, route_doc} -> [route_doc | generate_docs_for_routes]
        _ -> generate_docs_for_routes
      end
    end)
    |> Enum.reverse()
  end

  @spec process_route(%PhxRoute{}, [Request.t()]) :: {:ok, Route.t()} | :error
  defp process_route(route, requests) do
    controller = Module.concat([:"Elixir" | Module.split(route.plug)])
    method = route.verb |> Atom.to_string() |> String.upcase()

    route_requests =
      Enum.filter(requests, fn request ->
        request.method == method and request.path == route.path
      end)

    try do
      route_docs =
        controller
        |> apply(:api_doc, [method, route.path])
        |> set_group(controller, route)
        |> Map.put(:requests, route_requests)
        |> remove_path_prefix()

      {:ok, route_docs}
    rescue
      UndefinedFunctionError ->
        Logger.warn(fn -> "No api doc defined for #{method} #{route.path}." end)
        :error

      FunctionClauseError ->
        Logger.warn(fn -> "No api doc defined for #{method} #{route.path}." end)
        :error
    end
  end

  @spec remove_path_prefix(Route.t()) :: Route.t()
  defp remove_path_prefix(route) do
    new_path =
      route.path
      |> trim_path()
      |> add_slash()

    %{route | path: new_path}
  end

  @spec trim_path(String.t()) :: String.t()
  defp trim_path(path) do
    to_trim = Keyword.get(blue_bird_config(), :trim_path, "")

    if path == to_trim, do: "/", else: String.trim_leading(path, to_trim <> "/")
  end

  @spec add_slash(String.t()) :: String.t()
  defp add_slash(path) do
    if String.starts_with?(path, "/"), do: path, else: "/" <> path
  end

  @spec set_group(Route.t(), module, PhxRoute.t()) :: Route.t()
  defp set_group(route_docs, controller, route) do
    group_name = get_group_name(controller, route)
    Map.put(route_docs, :group, group_name)
  end

  @spec get_group_name(module, PhxRoute.t()) :: String.t()
  defp get_group_name(controller, route) do
    apply(controller, :api_group, []).name
  rescue
    UndefinedFunctionError ->
      route.plug
      |> Naming.resource_name("Controller")
      |> Naming.humanize()
  end

  @spec blue_bird_config() :: Keyword.t()
  def blue_bird_config() do
    Project.get().project()
    |> Keyword.get(:app)
    |> Application.get_env(:blue_bird, [])
  end
end
