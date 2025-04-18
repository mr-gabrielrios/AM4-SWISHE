# atmos_phys
This is the repository that combines the atmosphere physics and chemistry
## Table of contents
* [Guidelines for Contributing](README.md#guidelines-for-contributing)
* [Instructions on merging in code from atmos_param or atmos_shared](README.md#instructions-on-merging-in-code-from-atmos_param-or-atmos_shared)
* [XML changes to checkout atmos_phys](README.md#xml-changes-to-checkout-atmos_phys)
## Guidelines for Contributing
If you have code you would like to contribute, you will first create a git branch.
Your branch should be in the format of /user/**ini**/**BranchName** where **ini** 
are your initals and **BranchName** is a name that describes the purpose of your
branch.  Avoid using a BranchName like *bugfix* or *update* because this is not
descritive.  
```bash
git checkout -b user/ini/BranchName
```
Second, you will commit your changes, and push them to the atmos_phys remote 
repository.  
```bash
git push -u origin user/ini/BranchName
```
After the changes are pushed, you can share your code with others.  If your code 
should be included in the main model development, you can submit a merge request by 
clicking on the Merge Requests link on the gitlab page.  Please include a detailed
description of the changes made by your branch.  You should submit the merge to the 
main development branch (*master*).  Assign your merge request to Uriel Ramirez.

## Instructions on merging in code from atmos_param or atmos_shared
In order to commit changes that currently exist on atmos_param or atmos_shared,
you first have to commit and push the changes to a branch in the repository you are 
working in. Next you will clone atmos_phys.  After that, you will add the original 
repository to as a remote in your atmos_phys directory.  You can then fetch from the
original repository and merge in the branch you were working on.

Below is an example set of instructions to accomplish this.  This assumes that you 
cloned atmos_param.
```bash
git clone https://gitlab.gfdl.noaa.gov/fms/atmos_phys.git #clone atmos_param
cd atmos_phys 
pushd ../atmos_param/ #Set up a directory stack with the two repo directories
git checkout user/ter/exampleBranch #check out your user branch
git fetch #fetch any changes that may have occurred in atmos_param since you branched
git pull origin/master #merge in the master (update your code base)
## The following 3 lines can be skipped if you already have committed changes ##
touch test.file #Make your changes (DO NOT COPY THIS, it is just an example)
git add test.file #stage your changes
git commit -m "Save a test commit to user branch" #commit your changes
## The folowing can be skipped if you have already pushed your changes ##
git push -u origin user/ter/exampleBranch
pushd #change directory to the atmos_phys folder
git checkout -b user/ter/exampleBranch #create your branch in atmos_phys
git remote add param https://gitlab.gfdl.noaa.gov/fms/atmos_param.git #add atmos_param as a remote
git fetch param #fetch the contents of the atmos_param
git merge param/user/ter/exampleBranch #merge your branch from atmos_param into your branch on atmos_phys
git push -u origin user/ter/exampleBranch
```
A note on git remotes: 

The default name for a remote is **origin**.  When you clone a repository, the remote 
is automatically given the name **origin**.  When you add a remote, you can name it 
anything except origin.  In the above example, I named the remote **param**.  That's 
why I fetch from **param**.  To see what remotes you have set up, you can issue the 
command
```bash
git remote -v
```

## XML changes to checkout atmos_phys
There are a few modifications to an XML in order switch to the atmos_phys code. 
An XML will have a section in the compile experiment that looks like the following:
```xml
    <component name="atmos_phys" requires="fms" paths="atmos_param atmos_shared">
      <description domainName="" communityName="" communityVersion="$(RELEASE)" communityGrid=""/>
      <source versionControl="git" root="http://gitlab.gfdl.noaa.gov/fms">
        <codeBase version="$(RELEASE)"> atmos_shared.git atmos_param.git </codeBase>
          <csh><![CDATA[
            ( cd atmos_shared && git checkout $(ATMOS_GIT_TAG) )
            ( cd atmos_param  && git checkout $(ATMOS_GIT_TAG) )
           ]]>
          </csh>
      </source>
      <compile>
        <cppDefs>$(F2003_FLAGS) -DCLUBB</cppDefs>
      </compile>
    </component>
```
This can be found by searching the XML for *atmos_phys* or *atmos_shared.git* or 
*atmos_param.git*. This <component> block should be updated to the following:
```xml
    <component name="atmos_phys" requires="fms" paths="atmos_phys">
      <description domainName="" communityName="" communityVersion="$(RELEASE)" communityGrid=""/>
      <source versionControl="git" root="http://gitlab.gfdl.noaa.gov/fms">
        <codeBase version="$(RELEASE)"> atmos_phys.git </codeBase>
          <csh><![CDATA[
            ( cd atmos_phys  && git checkout $(ATMOS_GIT_TAG) )
           ]]>
          </csh>
      </source>
      <compile>
        <cppDefs>$(F2003_FLAGS) -DCLUBB</cppDefs>
      </compile>
    </component>
```
1. The **paths** has been changed from "atmos_param atmos_shared" to "atmos_phys".
2. The **codeBase** was changed from **atmos_shared.git atmos_param.git** to **atmos_phys.git**
3. The `csh` block was updated to only `cd` to atmos_phys

NOTE: Users should switch to atmos_phys if they are checking out code that is newer 
than xanadu.  If your model is running code older than xanadu, you should check the 
code out from atmos_shared and atmos_param.
