require 'lockfile'
require 'net/ssh'
require 'tmpdir'

require 'gitolite_conf.rb'

module GitHosting
	def self.repository_name project
		parent_name = project.parent ? repository_name(project.parent) : ""
		return "#{parent_name}/#{project.identifier}".sub(/^\//, "")
	end
	
	def self.add_route_for_project(p)
		
		if defined? map
			add_route_for_project_with_map p, map
		else
			ActionController::Routing::Routes.draw do |map|
				add_route_for_project_with_map p, map
			end
		end
	end
	def self.add_route_for_project_with_map(p,m)
		repo = p.repository
		if repo.is_a?(Repository::Git)
			repo_path=repo.url.split(Setting.plugin_redmine_git_hosting['gitRepositoryBasePath'])[1]
			m.connect repo_path,                  :controller => 'git_http', :p1 => '', :p2 =>'', :p3 =>'', :id=>"#{p[:identifier]}", :path=>"#{repo_path}"
			m.connect repo_path + "/:p1",         :controller => 'git_http', :p2 => '', :p3 =>'', :id=>"#{p[:identifier]}", :path=>"#{repo_path}"
			m.connect repo_path + "/:p1/:p2",     :controller => 'git_http', :p3 => '', :id=>"#{p[:identifier]}", :path=>"#{repo_path}"
			m.connect repo_path + "/:p1/:p2/:p3", :controller => 'git_http', :id=>"#{p[:identifier]}", :path=>"#{repo_path}"
		end
	end

	def self.get_tmp_dir
		@@git_hosting_tmp_dir ||= File.join(Dir.tmpdir, "redmine_git_hosting")
		if !File.directory?(@@git_hosting_tmp_dir)
			%x[mkdir -p "#{@@git_hosting_tmp_dir}"]
		end
		return @@git_hosting_tmp_dir
	end

	def self.git_exec_path
		return File.join(get_tmp_dir(), "run_git_as_git_user")
	end
	def self.gitolite_ssh_path
		return File.join(get_tmp_dir(), "gitolite_admin_ssh")
	end
	def self.git_user_runner_path
		return File.join(get_tmp_dir(), "run_as_git_user")
	end

	def self.git_exec
		if !File.exists?(git_exec_path())
			update_git_exec
		end
		return git_exec_path()
	end
	def self.gitolite_ssh
		if !File.exists?(gitolite_ssh_path())
			update_git_exec
		end
		return gitolite_ssh_path()
	end
	def self.git_user_runner
		if !File.exists?(git_user_runner_path())
			update_git_exec
		end
		return git_user_runner_path()
	end

	def self.update_git_exec
		git_user=Setting.plugin_redmine_git_hosting['gitUser'] 
		git_user_server=git_user + "@" + Setting.plugin_redmine_git_hosting['gitServer']
		git_user_key=Setting.plugin_redmine_git_hosting['gitUserIdentityFile']
		gitolite_key=Setting.plugin_redmine_git_hosting['gitoliteIdentityFile']
		ssh_options=Setting.plugin_redmine_git_hosting['sshOptions']
		File.open(git_exec_path(), "w") do |f|
			f.puts '#!/bin/sh'
			f.puts 'cmd=$(printf "\"%s\" " "$@")'
			f.puts "if [ \"\$USER\" = \"#{git_user}\" ] ; then"
			f.puts '	cd ~'
			f.puts '	eval "git $cmd"'
			f.puts "else"
			f.puts "	ssh #{ssh_options} -i #{git_user_key} #{git_user_server} \"git $cmd\""
			f.puts 'fi'
		end
		File.open(gitolite_ssh_path(), "w") do |f|
			f.puts "#!/bin/sh"
			f.puts "exec ssh #{ssh_options} -i #{gitolite_key} \"$@\""
		end
		File.open(git_user_runner_path(), "w") do |f|
			f.puts "#!/bin/sh"
			f.puts "if [ \"\$USER\" = \"#{git_user}\" ] ; then"
			f.puts "	cd ~"
			f.puts "	$@"
			f.puts "else"
			f.puts "	ssh #{ssh_options} -i #{git_user_key} #{git_user_server} \"$@\""
			f.puts "fi"
		end

		File.chmod(0777, git_exec_path())
		File.chmod(0777, gitolite_ssh_path())
		File.chmod(0777, git_user_runner_path())

	end

	def self.update_repositories(projects, is_repo_delete)
		projects = (projects.is_a?(Array) ? projects : [projects])

		if(defined?(@recursionCheck))
			if(@recursionCheck)
				return
			end
		end
		@recursionCheck = true

		# Don't bother doing anything if none of the projects we've been handed have a Git repository
		unless projects.detect{|p|  p.repository.is_a?(Repository::Git) }.nil?
			
			#return cleanly if we don't have permissions to load identity file, which we need
			if !File.owned?(Setting.plugin_redmine_git_hosting['gitUserIdentityFile'])
				return
			end



			# create tmp dir, return cleanly if, for some reason, we don't have proper permissions
			local_dir = get_tmp_dir()
			
			#lock
			lockfile=File.new(File.join(local_dir,'redmine_git_hosting_lock'),File::CREAT|File::RDONLY)
			retries=5
			loop do
				break if lockfile.flock(File::LOCK_EX|File::LOCK_NB)
				retries-=1
				sleep 2
				if retries<=0
					return
				end
			end
			


			# clone/pull from admin repo
			if File.exists? "#{local_dir}/gitolite-admin"
				%x[env GIT_SSH=#{gitolite_ssh()} git --git-dir='#{local_dir}/gitolite-admin/.git' --work-tree='#{local_dir}/gitolite-admin' pull]
			else
				%x[env GIT_SSH=#{gitolite_ssh()} git clone #{Setting.plugin_redmine_git_hosting['gitUser']}@#{Setting.plugin_redmine_git_hosting['gitServer']}:gitolite-admin.git #{local_dir}/gitolite-admin]
			end
			%x[chmod 700 "#{local_dir}/gitolite-admin" ]
			conf = GitoliteConfig.new(File.join(local_dir, 'gitolite-admin', 'conf', 'gitolite.conf'))
			orig_repos = conf.all_repos
			new_repos = []
			changed = false

			projects.select{|p| p.repository.is_a?(Repository::Git)}.each do |project|
				
				repo_name = repository_name(project)
				
				#check for delete -- if delete we can just
				#delete repo, and ignore updating users/public keys
				if is_repo_delete
					if Setting.plugin_redmine_git_hosting['deleteGitRepositories'] == "true"
						conf.delete_repo(repo_name)
					end
				else
					#check whether we're adding a new repo
					if orig_repos[ repo_name ] == nil
						changed = true
						add_route_for_project(project)
						new_repos.push repo_name
					end


					# fetch users
					users = project.member_principals.map(&:user).compact.uniq
					write_users = users.select{ |user| user.allowed_to?( :commit_access, project ) }
					read_users = users.select{ |user| user.allowed_to?( :view_changesets, project ) && !user.allowed_to?( :commit_access, project ) }
				
					# write key files
					users.map{|u| u.gitolite_public_keys.active}.flatten.compact.uniq.each do |key|
						filename = File.join(local_dir, 'gitolite-admin/keydir',"#{key.identifier}.pub")
						unless File.exists? filename
							File.open(filename, 'w') {|f| f.write(key.key.gsub(/\n/,'')) }
							changed = true
						end
					end

				

					# delete inactives
					users.map{|u| u.gitolite_public_keys.inactive}.flatten.compact.uniq.each do |key|
						filename = File.join(local_dir, 'gitolite-admin/keydir',"#{key.identifier}.pub")
						if File.exists? filename
							File.unlink(filename) rescue nil
							changed = true
						end
					end

					# update users
					read_user_keys = []
					write_user_keys = []
					read_users.map{|u| u.gitolite_public_keys.active}.flatten.compact.uniq.each do |key|
						read_user_keys.push key.identifier
					end
					write_users.map{|u| u.gitolite_public_keys.active}.flatten.compact.uniq.each do |key|
						write_user_keys.push key.identifier
					end

					#git daemon
					if (project.repository.git_daemon == 1 || project.repository.git_daemon == nil )  && project.is_public
						read_user_keys.push "daemon"
					end

					conf.set_read_user repo_name, read_user_keys
					conf.set_write_user repo_name, write_user_keys	
				end
			end
			
			if conf.changed?
				conf.save
				changed = true
			end

			if changed
				%x[env GIT_SSH=#{gitolite_ssh()} git --git-dir='#{local_dir}/gitolite-admin/.git' --work-tree='#{local_dir}/gitolite-admin' add keydir/*]
				%x[env GIT_SSH=#{gitolite_ssh()} git --git-dir='#{local_dir}/gitolite-admin/.git' --work-tree='#{local_dir}/gitolite-admin' add conf/gitolite.conf]
				%x[env GIT_SSH=#{gitolite_ssh()} git --git-dir='#{local_dir}/gitolite-admin/.git' --work-tree='#{local_dir}/gitolite-admin' config user.email '#{Setting.mail_from}']
				%x[env GIT_SSH=#{gitolite_ssh()} git --git-dir='#{local_dir}/gitolite-admin/.git' --work-tree='#{local_dir}/gitolite-admin' config user.name 'Redmine']
				%x[env GIT_SSH=#{gitolite_ssh()} git --git-dir='#{local_dir}/gitolite-admin/.git' --work-tree='#{local_dir}/gitolite-admin' commit -a -m 'updated by Redmine' ]
				%x[env GIT_SSH=#{gitolite_ssh()} git --git-dir='#{local_dir}/gitolite-admin/.git' --work-tree='#{local_dir}/gitolite-admin' push ]

				#git_push_file = File.join(local_dir, 'git_push.sh')
				#new_dir= File.join(local_dir,'gitolite')
				#File.open(git_push_file, "w") do |f|
				#	f.puts "#!/bin/sh" 
				#	f.puts "cd #{new_dir}"
				#	f.puts "git add keydir/*"
				#	f.puts "git add conf/gitolite.conf"
				#	f.puts "git config user.email '#{Setting.mail_from}'"
				#	f.puts "git config user.name 'Redmine'"
				#	f.puts "git commit -a -m 'updated by Redmine'"
				#	f.puts "env GIT_SSH=#{gitolite_ssh()} git push"
				#end
				#File.chmod(0755, git_push_file)

				# add, commit, push, and remove local tmp dir
				#%x[sh #{git_push_file}]
			end

			#set post recieve hooks
			#need to do this AFTER push, otherwise necessary repos may not be created yet
			if new_repos.length > 0
				server_test = %x[#{git_user_runner} 'ruby #{RAILS_ROOT}/script/runner -e production "print \\\"good\\\"" 2>/dev/null']
				if server_test.match(/good/)
					new_repos.each do |repo_name|
						hook_file=Setting.plugin_redmine_git_hosting['gitRepositoryBasePath'] + repo_name + ".git/hooks/post-receive"
						%x[#{git_user_runner} 'echo "#!/bin/sh" > #{hook_file} ; echo "ruby #{RAILS_ROOT}/script/runner -e production Repository.fetch_changesets >/dev/null 2>&1" >>#{hook_file} ; chmod 700 #{hook_file} ']
					end
				end
			end

			lockfile.flock(File::LOCK_UN)
		end
		@recursionCheck = false

	end

end

