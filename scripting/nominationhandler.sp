#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "0.3"
#define MAX_MAP_LENGTH 96
#define MATCHED_INDEXES_MAX 14

#include <sourcemod>
#include <mapchooser>

KeyValues
	// Stores map file as a keyvalues object.
	g_kvMaps;
ArrayList
	// ArrayList containing full list of maps excluding current map
	g_arrMapCycle
	// ArrayList containing map group names for retrieving arraylists from the map group stringmap
	, g_arrMapGroupNames;
StringMap
	// StringMap containing map group names as strings and ArrayLists of each group {"GroupName", ArrayList}
	g_smMapGroups; 

public Plugin myinfo = {
	name = "[ECJS] Simple Nomination Handler",
	author = "JoinedSenses",
	description = "A simple nomination handler",
	version = PLUGIN_VERSION,
	url = "https://github.com/JoinedSenses"
};

// ------------------------------------ SM Forwards

public void OnPluginStart() {
	CreateConVar("sm_nominationhandler_version", PLUGIN_VERSION, "ECJS Nomination Handler",  FCVAR_NOTIFY|FCVAR_DONTRECORD);

	RegConsoleCmd("sm_nom", cmdNominate);
	RegConsoleCmd("sm_nominate", cmdNominate);
	RegAdminCmd("sm_updatemaplist", cmdUpdateMapList, ADMFLAG_ROOT);

	g_kvMaps = new KeyValues("MapList");
	g_kvMaps.ImportFromFile("cfg/sourcemod/maphandler/_mapcycle.txt");
	g_arrMapCycle = new ArrayList(ByteCountToCells(MAX_MAP_LENGTH));
	g_arrMapGroupNames = new ArrayList(ByteCountToCells(128));
	g_smMapGroups = new StringMap();

	// 10 second timer for loading map cycle to spread out server workload
	CreateTimer(10.0, timerLoadMapCycle);
}

// ------------------------------------ Map Loader

Action timerLoadMapCycle(Handle timer) {
	LoadMapCycle();
}

bool LoadMapCycle() {
	char sectionName[128];
	char mapName[MAX_MAP_LENGTH];

	// Jump into the first subsection
	if (!g_kvMaps.GotoFirstSubKey()) {
		delete g_kvMaps;
		return false;
	}
	ArrayList mapGroup;
	// Iterate over subsections at the same nesting level
	do {
		mapGroup = new ArrayList(ByteCountToCells(32));
		g_kvMaps.GetSectionName(sectionName, sizeof(sectionName));

		// Iterate through subsection and begin getting key values of map names
		if (!g_kvMaps.GotoFirstSubKey(false)) {
			delete g_kvMaps;
			return false;
		}
		do {
			g_kvMaps.GetString(NULL_STRING, mapName, sizeof(mapName));
			// Add each map from the keyvalues to MapCycle and each group arraylist
			g_arrMapCycle.PushString(mapName);
			mapGroup.PushString(mapName);
		} while (g_kvMaps.GotoNextKey(false));

		g_kvMaps.GoBack();
		// Push section name to array list for future reference and add mapgroup arraylist to global stringmap
		g_arrMapGroupNames.PushString(sectionName);
		g_smMapGroups.SetValue(sectionName, mapGroup);

	} while (g_kvMaps.GotoNextKey());

	delete g_kvMaps;
	return true;
}

// ------------------------------------ Public

public Action cmdNominate(int client, int args) {
	// Display main menu when 0 args
	if (args == 0) {
		DisplayMapGroups(client);
		return Plugin_Handled;
	}

	char input[MAX_MAP_LENGTH];
	char mapResult[MAX_MAP_LENGTH];
	GetCmdArg(1, input, sizeof(input));

	// Results contains the indexes of the results within the map cycle arraylist
	ArrayList results = new ArrayList();
	int matches = FindMatchingMaps(g_arrMapCycle, results, input);
	
	// No results
	if (matches <= 0) {
		ReplyToCommand(client, "\x01[\x03ECJS\x01] No nomination match");
	}
	// Multiple results
	else if (matches > 1) {
		// Display results to the client and end
		Menu menu = new Menu(MapList_MenuHandler, MENU_ACTIONS_DEFAULT|MenuAction_DrawItem|MenuAction_DisplayItem);
		menu.SetTitle("Select map");
		
		for (int i = 0; i < results.Length; i++) {
			g_arrMapCycle.GetString(results.Get(i), mapResult, sizeof(mapResult));
			menu.AddItem(mapResult, mapResult);
		}

		menu.Display(client, MENU_TIME_FOREVER);
		ReplyToCommand(client, "\x01[\x03ECJS\x01] Found multiple matches");
	}
	// One result
	else if (matches == 1) {
		// Get the result and nominate it
		g_arrMapCycle.GetString(results.Get(0), mapResult, sizeof(mapResult));
		AttemptNominate(client, mapResult);
	}

	delete results;

	return Plugin_Handled;
}

// ------------------------------------ Admin

// Updates mapcycle.txt with maps from ecj_mapcycle.txt
public Action cmdUpdateMapList(int client, int args) {
	if (!g_arrMapCycle.Length) {
		ReplyToCommand(client, "\x01[\x03ECJS\x01] Error reading map cycle. (Array Length: %i)", g_arrMapCycle.Length);
		return Plugin_Handled;
	}
	File file = OpenFile("cfg/mapcycle.txt", "w");

	if (file == null) {
		ReplyToCommand(client, "\x01[\x03ECJS\x01] Error opening file.");
		return Plugin_Handled;
	}

	char mapName[MAX_MAP_LENGTH];
	for (int i = 0; i < g_arrMapCycle.Length; i++) {
		g_arrMapCycle.GetString(i, mapName, sizeof(mapName));
		file.WriteLine(mapName);
	}
	delete file;
	ReplyToCommand(client, "\x01[\x03ECJS\x01] Success! mapcycle.txt updated.");
	return Plugin_Handled;
}

// ------------------------------------ Internal Menus
void DisplayMapGroups(int client) {
	char mapGroupName[MAX_MAP_LENGTH];
	Menu menu = new Menu(GroupList_MenuHandler);
	menu.SetTitle("Nomination Menu");

	for (int i = 0; i < g_arrMapGroupNames.Length; i++) {
		// Add and display each map group
		g_arrMapGroupNames.GetString(i, mapGroupName, sizeof(mapGroupName));
		menu.AddItem(mapGroupName, mapGroupName);
	}

	menu.Display(client, MENU_TIME_FOREVER);
}

void DisplayMapsFromGroup(int client, ArrayList arrMapGroup, const char[] groupName) {
	Menu menu = new Menu(MapList_MenuHandler, MENU_ACTIONS_DEFAULT|MenuAction_DrawItem|MenuAction_DisplayItem);
	menu.SetTitle("%s Maps", groupName);
	menu.ExitBackButton = true;
	char mapName[MAX_MAP_LENGTH];

	for (int i = 0; i < arrMapGroup.Length; i++) {
		// Display all maps from group
		arrMapGroup.GetString(i, mapName, sizeof(mapName));
		menu.AddItem(mapName, mapName);
	}

	menu.Display(client, MENU_TIME_FOREVER);
}

// ------------------------------------ Menu Handlers

int GroupList_MenuHandler(Menu menu, MenuAction action, int param1, int param2) {
	switch (action) {
		case MenuAction_Select: {
			ArrayList mapGroup;
			char mapGroupName[MAX_MAP_LENGTH];

			// Grab the group name via the selection
			menu.GetItem(param2, mapGroupName, sizeof(mapGroupName));
			// Get the group arraylist by name string from the stringmap
			g_smMapGroups.GetValue(mapGroupName, mapGroup);
			// Create new menu
			DisplayMapsFromGroup(param1, mapGroup, mapGroupName);
		}
		case MenuAction_End: {
			delete menu;
		}
	}
}

int MapList_MenuHandler(Menu menu, MenuAction action, int param1, int param2) {
	switch (action) {
		case MenuAction_DisplayItem: {
			char mapName[MAX_MAP_LENGTH];
			menu.GetItem(param2, mapName, sizeof(mapName));
			char currentMap[MAX_MAP_LENGTH];
			GetCurrentMap(currentMap, sizeof(currentMap));
			if (StrEqual(mapName, currentMap)) {
				char display[150];
				Format(display, sizeof(display), "%s (Current)", mapName);
				return RedrawMenuItem(display);
			}
		}
		case MenuAction_DrawItem: {
			char mapName[MAX_MAP_LENGTH];
			menu.GetItem(param2, mapName, sizeof(mapName));
			char currentMap[MAX_MAP_LENGTH];
			GetCurrentMap(currentMap, sizeof(currentMap));
			if (StrEqual(mapName, currentMap)) {
				return ITEMDRAW_DISABLED;
			}

			return ITEMDRAW_DEFAULT;
		}
		case MenuAction_Select: {
			char mapName[MAX_MAP_LENGTH];
			// Get the map name and attempt to nominate it
			menu.GetItem(param2, mapName, sizeof(mapName));
			AttemptNominate(param1, mapName);
		}
		case MenuAction_Cancel: {
			if (param2 == MenuCancel_ExitBack){
				// Return to previous menu if selection == exitback
				DisplayMapGroups(param1);
			}
		}
		case MenuAction_End: {
			delete menu;
		}
	}
	return 0;
}

// ------------------------------------ Internal Functions

void AttemptNominate(int client, const char[] mapName) {
	char unused[MAX_MAP_LENGTH];
	if (FindMap(mapName, unused, sizeof(unused)) == FindMap_NotFound) {
		ReplyToCommand(client, "\x01[\x03ECJS\x01] %s in mapcycle, but not on server. Please report this error.", mapName);
		return;
	}

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
		if (StrContains(map, input) != -1) {
			results.Push(i);
			matches++;

			if (matches >= MATCHED_INDEXES_MAX) {
				break;
			}
		}
	}

	return matches;
}