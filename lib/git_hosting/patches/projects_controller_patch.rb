require_dependency 'projects_controller'
module GitHosting
	module Patches
		module ProjectsControllerPatch
			
			def git_repo_init
				
				users = @project.member_principals.map(&:user).compact.uniq
				if users.length == 0
					membership = Member.new(
						:principal=>User.current,
						:project_id=>@project.id,
						:role_ids=>[3]
						)
					membership.save
				end
				if Setting.plugin_redmine_git_hosting['allProjectsUseGit'] == "true"
					repo = Repository::Git.new
					repo_name = GitHosting.repository_name(@project)
					repo.url = repo.root_url = File.join(Setting.plugin_redmine_git_hosting['gitRepositoryBasePath'], "#{repo_name}.git")
					@project.repository = repo
				end

			end
			
			def disable_git_daemon_if_not_public
				if @project.repository != nil
					if @project.repository != nil
						if @project.repository.is_a?(Repository::Git)
							if @project.repository.git_daemon == 1 && (not @project.is_public )
								@project.repository.git_daemon = 0;
								@project.repository.save
							end
						end
					end
				end
			end


			def self.included(base)
				base.class_eval do
					unloadable
				end
				base.send(:after_filter, :git_repo_init, :only=>:create)
				base.send(:after_filter, :disable_git_daemon_if_not_public, :only=>:update)
			end
		end
	end
end
ProjectsController.send(:include, GitHosting::Patches::ProjectsControllerPatch) unless ProjectsController.include?(GitHosting::Patches::ProjectsControllerPatch)
