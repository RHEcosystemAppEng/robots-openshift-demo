#!/usr/bin/env python3
"""Minimal Nav2 launch: core navigation only, no docking/route/collision servers."""

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    params_file = LaunchConfiguration("params_file")
    use_sim_time = LaunchConfiguration("use_sim_time", default="true")

    declare_params = DeclareLaunchArgument(
        "params_file",
        default_value="/tmp/ros-home/nav2_params.yaml",
        description="Nav2 parameters file (envsubst-generated with ROBOT_NAME)",
    )
    declare_sim_time = DeclareLaunchArgument(
        "use_sim_time",
        default_value="true",
    )

    lifecycle_nodes = [
        "controller_server",
        "smoother_server",
        "planner_server",
        "behavior_server",
        "bt_navigator",
        "waypoint_follower",
        "velocity_smoother",
    ]

    return LaunchDescription([
        declare_params,
        declare_sim_time,

        Node(package="nav2_controller",   executable="controller_server",
             name="controller_server",  output="screen",
             parameters=[params_file, {"use_sim_time": use_sim_time}],
             remappings=[("/tf", "tf"), ("/tf_static", "tf_static")]),

        Node(package="nav2_smoother",     executable="smoother_server",
             name="smoother_server",    output="screen",
             parameters=[params_file, {"use_sim_time": use_sim_time}],
             remappings=[("/tf", "tf"), ("/tf_static", "tf_static")]),

        Node(package="nav2_planner",      executable="planner_server",
             name="planner_server",     output="screen",
             parameters=[params_file, {"use_sim_time": use_sim_time}],
             remappings=[("/tf", "tf"), ("/tf_static", "tf_static")]),

        Node(package="nav2_behaviors",    executable="behavior_server",
             name="behavior_server",    output="screen",
             parameters=[params_file, {"use_sim_time": use_sim_time}],
             remappings=[("/tf", "tf"), ("/tf_static", "tf_static"),
                         ("cmd_vel", "cmd_vel_nav")]),

        Node(package="nav2_bt_navigator", executable="bt_navigator",
             name="bt_navigator",       output="screen",
             parameters=[params_file, {"use_sim_time": use_sim_time}],
             remappings=[("/tf", "tf"), ("/tf_static", "tf_static")]),

        Node(package="nav2_waypoint_follower", executable="waypoint_follower",
             name="waypoint_follower",  output="screen",
             parameters=[params_file, {"use_sim_time": use_sim_time}],
             remappings=[("/tf", "tf"), ("/tf_static", "tf_static")]),

        Node(package="nav2_velocity_smoother", executable="velocity_smoother",
             name="velocity_smoother",  output="screen",
             parameters=[params_file, {"use_sim_time": use_sim_time}],
             remappings=[("/tf", "tf"), ("/tf_static", "tf_static"),
                         ("cmd_vel", "cmd_vel_smoothed"),
                         ("cmd_vel_smoothed", "cmd_vel")]),

        Node(package="nav2_lifecycle_manager", executable="lifecycle_manager",
             name="lifecycle_manager_navigation",
             output="screen",
             parameters=[params_file,
                         {"use_sim_time": use_sim_time,
                          "autostart": True,
                          "bond_timeout": 4.0,
                          "node_names": lifecycle_nodes}]),
    ])
