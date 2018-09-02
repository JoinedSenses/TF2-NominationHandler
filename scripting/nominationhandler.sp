#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "0.1"
#define MAX_MAP_LENGTH 96
#define MATCHED_INDEXES_MAX 10
// When set to 1, this will update mapcycle.txt with whatever is in the ecj_mapcycle
#define MAPFILE_UPDATE 0 

#include <sourcemod>
#include <mapchooser>

static KeyValues
	// Stores map file as a keyvalues object.
	g_kvMaps;
static ArrayList
	// ArrayList containing full list of maps excluding current map
	g_arrMapCycle
	// ArrayList containing each map group arraylist
	, g_arrMapGroups
	// ArrayList storing map group names
	, g_arrGroupNames;
ArrayList
	// ArrayList per map group
	g_arrMapGroup; 
static StringMap
	// StringMap containing map group names as strings and an index value for retrieval
	g_smMapGroupIndexes; 

public Plugin myinfo = {
	name = "[ECJS] Simple Nomination Handler",
	author = "JoinedSenses",
	description = "A simple nomination handler",
	version = PLUGIN_VERSION,
	url = "https://github.com/JoinedSenses"
};

// ------------------------------------ SM Forwards

public void OnPluginStart() {
	CreateConVar("sm_nominationhandler_version", PLUGIN_VERSION, "ECJS Nomination Handler",  FCVAR_NOTIFY | FCVAR_DONTRECORD);

	RegConsoleCmd("sm_nom", cmdNominate);
	RegConsoleCmd("sm_nominate", cmdNominate);

	if (g_kvMaps == null) {
		g_kvMaps = new KeyValues("MapList");
		g_kvMaps.ImportFromFile("cfg/sourcemod/maphandler/ecj_mapcycle.txt");
	}
	if (g_arrMapGroups == null) {
		g_arrMapGroups = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	}
	if (g_arrMapCycle == null) {
		g_arrMapCycle = new ArrayList(ByteCountToCells(MAX_MAP_LENGTH));
	}
	if (g_arrGroupNames == null) {
		g_arrGroupNames = new ArrayList(ByteCountToCells(MAX_MAP_LENGTH));
	}
	if (g_smMapGroupIndexes == null) {
		g_smMapGroupIndexes = new StringMap();
	}

	LoadMapCycle();
}

public void OnPluginEnd() {
	// Memory management
	delete g_kvMaps;
	ArrayList buffer;
	for (int i = 0; i < g_arrMapGroups.Length; i++) {
		buffer = g_arrMapGroups.Get(i);
		delete buffer;
	}
	delete g_arrMapGroups;
	delete g_arrGroupNames;
	delete g_smMapGroupIndexes;
}

// ------------------------------------ Map Loader

bool LoadMapCycle() {
	char buffer[MAX_MAP_LENGTH];
	// groupValue will be used for indexing groups and recalling them
	int groupValue = 0;

#if MAPFILE_UPDATE
	File file = OpenFile("cfg/mapcycle.txt", "w");
#endif

	// Jump into the first subsection
	if (!g_kvMaps.GotoFirstSubKey()) {
		delete g_kvMaps;
		return false;
	}
	// Iterate over subsections at the same nesting level
	do {
		g_arrMapGroup = new ArrayList(ByteCountToCells(32));
		g_kvMaps.GetSectionName(buffer, sizeof(buffer));
		g_arrGroupNames.PushString(buffer);
		g_smMapGroupIndexes.SetValue(buffer, groupValue);
		//g_arrMapGroups.PushString(buffer);

		// Iterate through subsection and begin getting key values of map names
		if (!g_kvMaps.GotoFirstSubKey(false)) {
			delete g_kvMaps;
			return false;
		}
		do {
			g_kvMaps.GetString(NULL_STRING, buffer, sizeof(buffer));
			// Add each map from the keyvalues to MapCycle and each group
			g_arrMapCycle.PushString(buffer);
			g_arrMapGroup.PushString(buffer);

#if MAPFILE_UPDATE
			char mapName[MAX_MAP_LENGTH];
			Format(mapName, sizeof(mapName), "%s\n", buffer);
			file.WriteString(mapName, true);
#endif
		} while (g_kvMaps.GotoNextKey(false));

		groupValue++;
		g_kvMaps.GoBack();
		// Add map group arraylist to a global reference arraylist
		g_arrMapGroups.Push(g_arrMapGroup);

	} while (g_kvMaps.GotoNextKey());

#if MAPFILE_UPDATE
	delete file;
#endif
	delete g_kvMaps;
	return true;
}

// ------------------------------------ Public

public Action cmdNominate(int client, int args) {
	// Display menu when 0 args
	if (args == 0) {
		char buffer[MAX_MAP_LENGTH];
		Menu menu = new Menu(NominationGroups_MenuHandler);
		menu.SetTitle("Nomination Menu");

		for (int i = 0; i < g_arrGroupNames.Length; i++) {
			// Add and display each map group
			g_arrGroupNames.GetString(i, buffer, sizeof(buffer));
			menu.AddItem(buffer, buffer);
		}

		menu.Display(client, MENU_TIME_FOREVER);
		return Plugin_Handled;
	}

	char arg[MAX_MAP_LENGTH], buffer[MAX_MAP_LENGTH];
	GetCmdArg(1, arg, sizeof(arg));

	// Run a fuzzy search on mapcycle arraylist and return count
	// Results contains the indexes of the results within the map cycle arraylist
	ArrayList results = new ArrayList();
	int matches = FindMatchingMaps(g_arrMapCycle, results, arg);

	// No results
	if (matches <= 0) {
		ReplyToCommand(client, "\x01[\x03ECJS\x01] No nomination match");
	}
	// Multiple results
	else if (matches > 1) {
		// Display results to the client and end
		ReplyToCommand(client, "\x01[\x03ECJS\x01] Found multiple matches");

		for (int i = 0; i < results.Length; i++) {
			g_arrMapCycle.GetString(results.Get(i), buffer, sizeof(buffer));
			ReplyToCommand(client, "\x01Map:\x03 %s", buffer);
		}
	}
	// One result
	else if (matches == 1) {
		// Get the result and nominate it
		g_arrMapCycle.GetString(results.Get(0), buffer, sizeof(buffer));
		AttemptNominate(client, buffer);
	}

	delete results;

	return Plugin_Handled;
}

// ------------------------------------ Internal Menus

void DisplayMapsFromGroup(int client, ArrayList arrMapGroup, const char[] groupName) {
	Menu menu = new Menu(GroupList_MenuHandler);
	menu.SetTitle("%s Maps", groupName);
	menu.ExitBackButton = true;
	char buffer[MAX_MAP_LENGTH];

	for (int i = 0; i < arrMapGroup.Length; i++) {
		// Display all maps from group
		arrMapGroup.GetString(i, buffer, sizeof(buffer));
		menu.AddItem(buffer, buffer);
	}

	menu.Display(client, MENU_TIME_FOREVER);
}

// ------------------------------------ Menu Handlers

int NominationGroups_MenuHandler(Menu menu, MenuAction action, int param1, int param2) {
	switch (action) {
		case MenuAction_Select: {
			ArrayList arrMapGroup;
			char mapGroupName[MAX_MAP_LENGTH];
			int mapGroupIndex;
			// Grab the group name via the selection
			menu.GetItem(param2, mapGroupName, sizeof(mapGroupName));
			// Get the group index and store in mapGroupIndex
			g_smMapGroupIndexes.GetValue(mapGroupName, mapGroupIndex);
			// Get the group handle by index from global group arraylist
			arrMapGroup = g_arrMapGroups.Get(mapGroupIndex);

			// Create new menu
			DisplayMapsFromGroup(param1, arrMapGroup, mapGroupName);
		}
		case MenuAction_End: {
			delete menu;
		}
	}
}

int GroupList_MenuHandler (Menu menu, MenuAction action, int param1, int param2) {
	switch (action) {
		case MenuAction_Select: {
			char buffer[MAX_MAP_LENGTH];
			// Get the map name and attempt to nominate it
			menu.GetItem(param2, buffer, sizeof(buffer));
			AttemptNominate(param1, buffer);
		}
		case MenuAction_Cancel:{
			if (param2 == MenuCancel_ExitBack){
				// Return to previous menu if selection == exitback
				cmdNominate(param1, 0);
			}
		}
		case MenuAction_End: {
			delete menu;
		}
	}
}

// ------------------------------------ Internal Functions

void AttemptNominate(int client, const char[] mapName) {
	NominateResult result = NominateMap(mapName, true, client);
	
	if (result == Nominate_AlreadyInVote) {
		ReplyToCommand(client, "\x01[\x03ECJS\x01] Map\x03 %s\x01 already in the nominations list.", mapName);
		return;
	}

	char name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));
	PrintToChatAll("\x01[\x03ECJS\x01]\x03 %s\x01 has nominated\x03 %s\x01.", name, mapName);
		
	return;
}

int FindMatchingMaps(ArrayList mapList, ArrayList results, const char[] input){
	int map_count = mapList.Length;

	if (!map_count) {
		return -1;
	}

	int matches = 0;
	char map[PLATFORM_MAX_PATH];

	for (int i = 0; i < map_count; i++) {
		mapList.GetString(i, map, sizeof(map));

		if (FuzzyCompare(input, map)) {
			results.Push(i);
			matches++;

			if (matches >= MATCHED_INDEXES_MAX) {
				break;
			}
		}
	}

	return matches;
}

int FuzzyCompare(const char[] needle, const char[] haystack) {
	int hlen = strlen(haystack);
	int nlen = strlen(needle);

	if (nlen > hlen) {
		return false;
	}
	if (nlen == hlen) {
		return strcmp(needle, haystack) == 0;
	}

	int n = 0;
	int h = 0;
	int p = 0;

	for (; n < nlen; n++) {
		int nch = needle[n];

		while (h < hlen) {
			if (nch == haystack[h]) {
				h++;
				p++;
				break;
			}
			h++;
		}
	}

	return (p == nlen);
}