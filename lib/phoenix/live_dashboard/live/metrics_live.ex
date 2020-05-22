defmodule Phoenix.LiveDashboard.MetricsLive do
  use Phoenix.LiveDashboard.Web, :live_view

  alias Phoenix.LiveDashboard.ChartComponent
  alias Phoenix.LiveDashboard.TelemetryListener

  @impl true
  def mount(params, %{"metrics" => {mod, fun}, "historical_data" => data} = session, socket) do
    all_metrics = apply(mod, fun, [])
    metrics_per_group = Enum.group_by(all_metrics, &group_name/1)

    group = params["group"]
    metrics = metrics_per_group[group]
    {first_group, _} = Enum.at(metrics_per_group, 0, {nil, nil})

    socket =
      socket
      |> assign_defaults(params, session)
      |> assign(group: group, groups: Map.keys(metrics_per_group))

    cond do
      !socket.assigns.menu.metrics ->
        {:ok, push_redirect(socket, to: live_dashboard_path(socket, :home, socket.assigns.menu.node))}

      group && is_nil(metrics) ->
        {:ok, push_redirect(socket, to: live_dashboard_path(socket, :metrics, node()))}

      metrics && connected?(socket) ->
        Phoenix.LiveDashboard.TelemetryListener.listen(socket.assigns.menu.node, metrics)
        {:ok, assign(socket, metrics: Enum.with_index(metrics), historical_data: data)}

      first_group && is_nil(group) ->
        {:ok,
         push_redirect(socket, to: live_dashboard_path(socket, :metrics, socket.assigns.menu.node, [first_group]))}

      true ->
        {:ok, assign(socket, metrics: nil)}
    end
  end

  defp group_name(metric) do
    to_string(metric.reporter_options[:group] || hd(metric.name))
  end

  defp format_group_name("vm"), do: "VM"
  defp format_group_name(group), do: Phoenix.Naming.camelize(group)

  @impl true
  def render(assigns) do
    ~L"""
    <div class="row">
      <div class="container">
        <ul class="nav nav-tabs mb-4 charts-nav">
          <%= for group <- @groups do %>
            <li class="nav-item">
              <%= live_redirect(format_group_name(group),
                    to: live_dashboard_path(@socket, :metrics, @menu.node, [group]),
                    class: "nav-link #{if @group == group, do: "active"}") %>
            </li>
          <% end %>
        </ul>
      </div>
    </div>

    <%= if @metrics do %>
      <div class="phx-dashboard-metrics-grid row">
      <%= for {metric, id} <- @metrics do %>
        <%= live_component @socket, ChartComponent, id: id, metric: metric,
          do: metric
              |> history_for(id, @historical_data)
              |> send_updates_for_entries()
        %>
      <% end %>
      </div>
    <% end %>
    """
  end

  defp send_updates_for_entries(entries) do
    for {id, label, measurement, time} <- entries do
      data = [{label, measurement, time}]
      send_update(ChartComponent, id: id, data: data)
    end
  end

  @impl true
  def handle_info({:telemetry, entries}, socket) do
    send_updates_for_entries(entries)
    {:noreply, socket}
  end

  def handle_info({:node_redirect, node}, socket) do
    args = if group = socket.assigns.group, do: [group], else: []
    {:noreply, push_redirect(socket, to: live_dashboard_path(socket, :metrics, node, args))}
  end

  defp history_for(_metric, _id, nil), do: []

  defp history_for(metric, id, historical_data) do
    case history_tuple(metric, historical_data) do
      nil ->
        []

      {_prefix, {module, function, opts}} ->
        history = apply(module, function, [metric | opts])

        for %{data: data, time: time} = map <- history do
          measurement = TelemetryListener.extract_measurement(metric, data)
          label = TelemetryListener.tags_to_label(metric, map[:metadata] || %{})
          {id, label, measurement, time}
        end
    end
  end

  defp history_tuple(%{name: metric_name}, historical_data) do
    Enum.find(historical_data, fn {metric_prefix, _tuple} ->
      List.starts_with?(metric_name, metric_prefix)
    end)
  end
end
