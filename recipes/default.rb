#
# Cookbook Name:: haproxy
# Recipe:: default
#
# Copyright 2009, Opscode, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

include_recipe "haproxy::install_#{node['haproxy']['install_method']}"

cookbook_file "/etc/default/haproxy" do
  source "haproxy-default"
  owner "root"
  group "root"
  mode 00644
  notifies :restart, "service[haproxy]"
end


if node['haproxy']['enable_admin']
  admin = node['haproxy']['admin']
  haproxy_lb "admin" do
    bind "#{admin['address_bind']}:#{admin['port']}"
    mode 'http'
    params({ 'stats' => 'uri /'})
  end
end

conf = node['haproxy']
member_max_conn = conf['member_max_connections']
member_weight = conf['member_weight']

if conf['enable_default_http']
  frontend_params = {
      'maxconn' => conf['frontend_max_connections'],
      'bind' => "#{conf['incoming_address']}:#{conf['incoming_port']}"
  }
  if conf['auto_redirect_ssl']
    frontend_params.merge!({'redirect' => "scheme https if !{ ssl_fc }"})
  else
    frontend_params.merge!({'default_backend' => 'servers-http'})
  end

  haproxy_lb 'http' do
    type 'frontend'
    params frontend_params
  end

  member_port = conf['member_port']
  pool = []
  pool << "option httpchk #{conf['httpchk']}" if conf['httpchk']
  servers = node['haproxy']['members'].map do |member|
    "#{member['hostname']} #{member['ipaddress']}:#{member['port'] || member_port} weight #{member['weight'] || member_weight} maxconn #{member['max_connections'] || member_max_conn} check"
  end
  if servers.any?
    haproxy_lb 'servers-http' do
      type 'backend'
      servers servers
      params pool
    end
  end
end


if node['haproxy']['enable_ssl']
  whitelist_ips = node['haproxy']['whitelist_ips'] || []
  whitelist_urls = node['haproxy']['whitelist_urls'] || []
  urls = whitelist_urls.collect {|url| "restricted_page path_beg #{url}"}
  acls = {}
  if urls.any?
    urls << "network_allowed src #{whitelist_ips.join(" ")}"
    acls['acl'] = urls
    acls['block'] = "if restricted_page !network_allowed"
  end

  haproxy_lb 'https' do
    type 'frontend'
    mode 'http'
    params({
      'maxconn' => node['haproxy']['frontend_ssl_max_connections'],
      'bind' => "#{node['haproxy']['ssl_incoming_address']}:#{node['haproxy']['ssl_incoming_port']} ssl crt #{node['haproxy']['ssl_crt_path']}",
      'default_backend' => 'servers-https',
      'reqadd' => 'X-Forwarded-Proto:\ https',
      'option' => ['httpclose', 'forwardfor']
    }.merge(acls))
  end

  ssl_member_port = conf['ssl_member_port']
  pool = ['option ssl-hello-chk']
  pool << "option httpchk #{conf['ssl_httpchk']}" if conf['ssl_httpchk']
  servers = node['haproxy']['members'].map do |member|
    "#{member['hostname']} #{member['ipaddress']}:#{member['ssl_port'] || ssl_member_port} weight #{member['weight'] || member_weight} maxconn #{member['max_connections'] || member_max_conn} check"
  end
  if servers.any?
    haproxy_lb 'servers-https' do
      type 'backend'
      mode 'tcp'
      servers servers
      params pool
    end
  end
end

# Re-default user/group to account for role/recipe overrides
node.default['haproxy']['stats_socket_user'] = node['haproxy']['user']
node.default['haproxy']['stats_socket_group'] = node['haproxy']['group']

template "#{node['haproxy']['conf_dir']}/haproxy.cfg" do
  source "haproxy.cfg.erb"
  owner "root"
  group "root"
  mode 00644
  notifies :reload, "service[haproxy]"
  variables(
    :defaults_options => haproxy_defaults_options,
    :defaults_timeouts => haproxy_defaults_timeouts
  )
end

service "haproxy" do
  supports :restart => true, :status => true, :reload => true
  action [:enable, :start]
end
